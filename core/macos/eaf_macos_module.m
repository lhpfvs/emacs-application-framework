/// eaf_macos_module.m
///
/// Emacs dynamic module for EAF on macOS.
///
/// Exposed Emacs Lisp functions
/// ────────────────────────────
///   (eaf-macos-start-python  W H SOURCE-DIR VENV-SITE)  → nil
///   (eaf-macos-alive-p)                                  → t / nil
///   (eaf-macos-call-python   METHOD ARG…)                → nil
///   (eaf-macos-service-bridge)                           → nil
///   (eaf-macos-update-views VIEW-SPECS)                 → nil
///   (eaf-macos-destroy-buffer-views BUFFER-ID)           → nil
///   (eaf-macos-activate-emacs-window [BUFFER-ID])        → nil

#import <Cocoa/Cocoa.h>
#include <Python.h>
#include <emacs-module.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#import "eaf_host_view.h"

int plugin_is_GPL_compatible;

// ══ Python embedding ══════════════════════════════════════════════════════════

static BOOL gPythonStarted    = NO;
static BOOL gEAFStarted       = NO;
static BOOL gEAFStartInProgress = NO;
static BOOL gEmacsShuttingDown = NO;
static PyObject *gEAFModule   = NULL;  // 'eaf' Python module (borrowed ref kept alive)

static void eaf_python_add_paths(const char *source_dir, const char *venv_site) {
    PyObject *sys  = PyImport_ImportModule("sys");
    if (!sys) { PyErr_Print(); return; }
    PyObject *path = PyObject_GetAttrString(sys, "path");
    if (!path) { PyErr_Print(); Py_DECREF(sys); return; }
    const char *dirs[2] = { source_dir, venv_site };
    for (int i = 0; i < 2; i++) {
        const char *s = dirs[i];
        if (s && *s) {
            PyObject *o = PyUnicode_FromString(s);
            if (o) { PyList_Append(path, o); Py_DECREF(o); }
        }
    }
    Py_DECREF(path);
    Py_DECREF(sys);
}

static NSString *extractNSString(emacs_env *env, emacs_value val) {
    ptrdiff_t len = 0;
    env->copy_string_contents(env, val, NULL, &len);
    char *buf = (char *)malloc((size_t)len);
    if (!buf) return @"";
    env->copy_string_contents(env, val, buf, &len);
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf);
    return s ? s : @"";
}

#define BRIDGE_QUEUE_CAP 128

typedef enum {
    BRIDGE_ASYNC = 0,
    BRIDGE_SYNC_FUNC,
    BRIDGE_SYNC_VAR,
    BRIDGE_ASYNC_FOCUS_BUFFER,
    BRIDGE_ASYNC_ACTIVATE_EMACS_WINDOW
} BridgeType;

typedef struct {
    BridgeType            type;
    char                 *data;    // heap-alloc'd sexp string (FUNC/ASYNC) or var name (VAR)
    PyObject             *result;  // filled by main thread; new ref handed to caller
    PyObject            **result_out; // caller-owned output slot for sync calls
    int                   error;   // 1 if Emacs signalled an error
    dispatch_semaphore_t  sem;     // NULL for ASYNC; signalled after result is set
} BridgeItem;

static BridgeItem     gBridgeQ[BRIDGE_QUEUE_CAP];
static int            gBridgeHead = 0;
static int            gBridgeTail = 0;
static pthread_mutex_t gBridgeMu  = PTHREAD_MUTEX_INITIALIZER;
static emacs_env      *gDirectBridgeEnv = NULL;
static char *emacs_value_to_sexp_string(emacs_env *env, emacs_value val);
static void activateEmacsWindowForBufferId(NSString *bufferId);

static void bridge_eval_async_direct(emacs_env *env, const char *sexp) {
    emacs_value eval_fn = env->intern(env, "eaf--eval-in-emacs");
    emacs_value data_val = env->make_string(env, sexp, strlen(sexp));
    emacs_value fa[] = {data_val};
    env->funcall(env, eval_fn, 1, fa);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
        env->non_local_exit_clear(env);
    }
}

static void bridge_focus_buffer_direct(emacs_env *env, const char *buffer_id) {
    emacs_value focus_fn = env->intern(env, "eaf-focus-buffer");
    emacs_value data_val = env->make_string(env, buffer_id, strlen(buffer_id));
    emacs_value fa[] = {data_val};
    env->funcall(env, focus_fn, 1, fa);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
        env->non_local_exit_clear(env);
    }
}

// ── Push a new item (caller must hold gBridgeMu) ──────────────────────────
static BridgeItem *bridge_alloc_item(void) {
    int next = (gBridgeTail + 1) % BRIDGE_QUEUE_CAP;
    if (next == gBridgeHead) return NULL;  // queue full
    BridgeItem *it = &gBridgeQ[gBridgeTail];
    gBridgeTail = next;
    return it;
}

static void bridge_enqueue_async_item(const char *data, BridgeType type) {
    pthread_mutex_lock(&gBridgeMu);
    BridgeItem *it = bridge_alloc_item();
    if (it) {
        it->type = type;
        it->data = data ? strdup(data) : NULL;
        it->result = NULL;
        it->result_out = NULL;
        it->error = 0;
        it->sem = NULL;
    }
    pthread_mutex_unlock(&gBridgeMu);
}

static PyObject *bridge_eval_sync_direct(emacs_env *env, const char *data, BridgeType type) {
    emacs_value func_fn = env->intern(env, "eaf--get-emacs-func-result");
    emacs_value var_fn  = env->intern(env, "eaf--get-emacs-var");
    emacs_value data_val = env->make_string(env, data, strlen(data));
    emacs_value fa[] = {data_val};
    emacs_value res =
        (type == BRIDGE_SYNC_FUNC)
        ? env->funcall(env, func_fn, 1, fa)
        : env->funcall(env, var_fn, 1, fa);

    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
        env->non_local_exit_clear(env);
        return PyUnicode_FromString("nil");
    }

    char *sexp_str = emacs_value_to_sexp_string(env, res);
    PyObject *py_result = PyUnicode_FromString(sexp_str);
    free(sexp_str);
    return py_result;
}

// ── Convert an emacs_value to a prin1 string (main thread) ────────────────
//   Returns a heap-alloc'd C string; caller must free.
static char *emacs_value_to_sexp_string(emacs_env *env, emacs_value val) {
    emacs_value prin1 = env->intern(env, "prin1-to-string");
    emacs_value sval  = env->funcall(env, prin1, 1, &val);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
        env->non_local_exit_clear(env);
        return strdup("nil");
    }
    ptrdiff_t len = 0;
    env->copy_string_contents(env, sval, NULL, &len);
    char *buf = malloc((size_t)len);
    if (!buf) return strdup("nil");
    env->copy_string_contents(env, sval, buf, &len);
    return buf;
}

// ── _eaf_bridge Python C extension ────────────────────────────────────────
//    Registered as a built-in module via PyImport_AppendInittab BEFORE
//    Py_Initialize(), so Python can `import _eaf_bridge` from any thread.
//
//    Calls made while Emacs is directly invoking Python on the main thread
//    are serviced inline. Out-of-band callbacks fall back to the queue, which
//    is drained from Emacs' post-command-hook.

static PyObject *bridge_eval_async(PyObject *self, PyObject *args) {
    const char *sexp;
    if (!PyArg_ParseTuple(args, "s", &sexp)) return NULL;
    if (gDirectBridgeEnv) {
        bridge_eval_async_direct(gDirectBridgeEnv, sexp);
        Py_RETURN_NONE;
    }
    bridge_enqueue_async_item(sexp, BRIDGE_ASYNC);
    Py_RETURN_NONE;
}

static PyObject *bridge_focus_buffer(PyObject *self, PyObject *args) {
    const char *buffer_id;
    if (!PyArg_ParseTuple(args, "s", &buffer_id)) return NULL;
    if (gDirectBridgeEnv) {
        bridge_focus_buffer_direct(gDirectBridgeEnv, buffer_id);
        Py_RETURN_NONE;
    }
    bridge_enqueue_async_item(buffer_id, BRIDGE_ASYNC_FOCUS_BUFFER);
    Py_RETURN_NONE;
}

static PyObject *bridge_activate_emacs_window(PyObject *self, PyObject *args) {
    const char *buffer_id = NULL;
    if (!PyArg_ParseTuple(args, "|z", &buffer_id)) return NULL;
    if (gDirectBridgeEnv) {
        NSString *bufferId = buffer_id ? [NSString stringWithUTF8String:buffer_id] : nil;
        activateEmacsWindowForBufferId(bufferId);
        Py_RETURN_NONE;
    }
    bridge_enqueue_async_item(buffer_id, BRIDGE_ASYNC_ACTIVATE_EMACS_WINDOW);
    Py_RETURN_NONE;
}

static PyObject *bridge_enqueue_sync(const char *data, BridgeType type) {
    if (gDirectBridgeEnv) {
        return bridge_eval_sync_direct(gDirectBridgeEnv, data, type);
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    PyObject *result = NULL;

    pthread_mutex_lock(&gBridgeMu);
    BridgeItem *it = bridge_alloc_item();
    if (!it) {
        pthread_mutex_unlock(&gBridgeMu);
        // sem released by ARC
        Py_RETURN_NONE;
    }
    it->type   = type;
    it->data   = strdup(data);
    it->result = NULL;
    it->result_out = &result;
    it->error  = 0;
    it->sem    = sem;
    pthread_mutex_unlock(&gBridgeMu);

    // Block calling Python thread; release GIL so the main thread can run.
    Py_BEGIN_ALLOW_THREADS
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    Py_END_ALLOW_THREADS
    // sem released by ARC when it goes out of scope

    PyObject *res = result ? result : (Py_INCREF(Py_None), Py_None);
    return res;
}

static PyObject *bridge_call_sync(PyObject *self, PyObject *args) {
    const char *sexp;
    if (!PyArg_ParseTuple(args, "s", &sexp)) return NULL;
    return bridge_enqueue_sync(sexp, BRIDGE_SYNC_FUNC);
}

static PyObject *bridge_get_var(PyObject *self, PyObject *args) {
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    return bridge_enqueue_sync(name, BRIDGE_SYNC_VAR);
}

static PyObject *bridge_is_embedded(PyObject *self, PyObject *args) {
    return PyBool_FromLong(1);
}

static PyMethodDef gBridgeMethods[] = {
    {"eval_async",   bridge_eval_async,   METH_VARARGS, "Fire-and-forget: eval sexp in Emacs."},
    {"focus_buffer", bridge_focus_buffer, METH_VARARGS, "Async: focus EAF buffer in Emacs by buffer id."},
    {"activate_emacs_window", bridge_activate_emacs_window, METH_VARARGS, "Async: activate Emacs window directly."},
    {"call_sync",    bridge_call_sync,    METH_VARARGS, "Sync call: eval sexp, return prin1 string."},
    {"get_var",      bridge_get_var,      METH_VARARGS, "Sync: return (prin1-to-string (eaf--get-emacs-var name))."},
    {"is_embedded",  bridge_is_embedded,  METH_VARARGS, "Return True when running in-process."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef gBridgeModuleDef = {
    PyModuleDef_HEAD_INIT, "_eaf_bridge", NULL, -1, gBridgeMethods
};

PyMODINIT_FUNC PyInit__eaf_bridge(void) {
    return PyModule_Create(&gBridgeModuleDef);
}

// ── (eaf-macos-service-bridge) → nil ──────────────────────────────────────
// Called from Emacs' post-command-hook on the main thread; drains the work
// queue for out-of-band Python callbacks.
static emacs_value
Fservice_bridge(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    emacs_value eval_fn = env->intern(env, "eaf--eval-in-emacs");
    emacs_value func_fn = env->intern(env, "eaf--get-emacs-func-result");
    emacs_value var_fn  = env->intern(env, "eaf--get-emacs-var");
    emacs_value focus_fn = env->intern(env, "eaf-focus-buffer");

    for (;;) {
        pthread_mutex_lock(&gBridgeMu);
        if (gBridgeHead == gBridgeTail) { pthread_mutex_unlock(&gBridgeMu); break; }
        // Copy item out (the slot may be reused once sem is signalled)
        BridgeItem item = gBridgeQ[gBridgeHead];
        gBridgeHead = (gBridgeHead + 1) % BRIDGE_QUEUE_CAP;
        pthread_mutex_unlock(&gBridgeMu);

        if (item.type == BRIDGE_ASYNC) {
            emacs_value data_val = env->make_string(env, item.data, strlen(item.data));
            free(item.data);
            emacs_value fa[] = {data_val};
            env->funcall(env, eval_fn, 1, fa);
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
                env->non_local_exit_clear(env);
            // No semaphore; continue draining.
            continue;
        }

        if (item.type == BRIDGE_ASYNC_FOCUS_BUFFER) {
            emacs_value data_val = env->make_string(env, item.data, strlen(item.data));
            free(item.data);
            emacs_value fa[] = {data_val};
            env->funcall(env, focus_fn, 1, fa);
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
                env->non_local_exit_clear(env);
            continue;
        }

        if (item.type == BRIDGE_ASYNC_ACTIVATE_EMACS_WINDOW) {
            NSString *bufferId = (item.data && item.data[0] != '\0')
                                 ? [NSString stringWithUTF8String:item.data]
                                 : nil;
            activateEmacsWindowForBufferId(bufferId);
            if (item.data) free(item.data);
            continue;
        }

        // Sync: call Emacs, convert result to prin1 string, wake caller.
        emacs_value data_val = env->make_string(env, item.data, strlen(item.data));
        free(item.data);
        emacs_value fa[] = {data_val};
        emacs_value res;
        if (item.type == BRIDGE_SYNC_FUNC)
            res = env->funcall(env, func_fn, 1, fa);
        else
            res = env->funcall(env, var_fn, 1, fa);

        PyObject *py_result;
        PyGILState_STATE pgs = PyGILState_Ensure();
        if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
            env->non_local_exit_clear(env);
            py_result = PyUnicode_FromString("nil");
        } else {
            char *sexp_str = emacs_value_to_sexp_string(env, res);
            py_result = PyUnicode_FromString(sexp_str);
            free(sexp_str);
        }
        PyGILState_Release(pgs);

        if (item.result_out) {
            *item.result_out = py_result;
        } else {
            Py_DECREF(py_result);
        }
        dispatch_semaphore_signal(item.sem);
    }
    return env->intern(env, "nil");
}

// ══ Emacs → Python direct calls ═══════════════════════════════════════════

// Get the live EAF Python instance (_eaf_embedded_instance in the eaf module).
static PyObject *get_eaf_instance(void) {
    if (!gEAFModule) return NULL;
    PyObject *inst = PyObject_GetAttrString(gEAFModule, "_eaf_embedded_instance");
    if (!inst || inst == Py_None) { Py_XDECREF(inst); return NULL; }
    return inst;  // new ref
}

static void eaf_python_resize_view(NSString *bufferId,
                                   uintptr_t hostWid,
                                   int width,
                                   int height) {
    if (width <= 0 || height <= 0) {
        return;
    }

    PyGILState_STATE gil = PyGILState_Ensure();

    PyObject *instance = get_eaf_instance();
    if (!instance) {
        PyGILState_Release(gil);
        return;
    }

    PyObject *method = PyObject_GetAttrString(instance, "native_resize_view");
    Py_DECREF(instance);
    if (!method) {
        PyErr_Clear();
        PyGILState_Release(gil);
        return;
    }

    PyObject *ret = PyObject_CallFunction(method,
                                          "sKii",
                                          bufferId.UTF8String,
                                          (unsigned long long)hostWid,
                                          width,
                                          height);
    if (!ret) {
        NSLog(@"[eaf-macos] native_resize_view raised");
        PyErr_Print();
    } else {
        Py_DECREF(ret);
    }

    Py_DECREF(method);
    PyGILState_Release(gil);
}

static void eaf_python_update_views(NSString *viewInfos) {
    PyGILState_STATE gil = PyGILState_Ensure();

    PyObject *instance = get_eaf_instance();
    if (!instance) {
        PyGILState_Release(gil);
        return;
    }

    PyObject *method = PyObject_GetAttrString(instance, "update_views");
    Py_DECREF(instance);
    if (!method) {
        PyErr_Clear();
        PyGILState_Release(gil);
        return;
    }

    PyObject *ret = PyObject_CallFunction(method, "s", viewInfos.UTF8String);
    if (!ret) {
        NSLog(@"[eaf-macos] update_views raised");
        PyErr_Print();
    } else {
        Py_DECREF(ret);
    }

    Py_DECREF(method);
    PyGILState_Release(gil);
}

static BOOL eaf_instance_ready(void) {
    if (!gPythonStarted || !gEAFModule) {
        return NO;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *inst = get_eaf_instance();
    BOOL ready = (inst != NULL);
    Py_XDECREF(inst);
    PyGILState_Release(gil);
    return ready;
}

static void clear_eaf_module_ref(void) {
    if (!gPythonStarted || !gEAFModule) {
        gEAFModule = NULL;
        return;
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    Py_CLEAR(gEAFModule);
    PyGILState_Release(gil);
}

static emacs_value python_result_to_emacs(emacs_env *env, PyObject *value) {
    if (!value || value == Py_None) return env->intern(env, "nil");
    if (PyBool_Check(value)) return env->intern(env, PyObject_IsTrue(value) ? "t" : "nil");
    if (PyLong_Check(value)) return env->make_integer(env, PyLong_AsLongLong(value));
    if (PyUnicode_Check(value)) {
        const char *s = PyUnicode_AsUTF8(value);
        return env->make_string(env, s ? s : "", s ? (ptrdiff_t)strlen(s) : 0);
    }

    PyObject *repr = PyObject_Str(value);
    if (!repr) {
        PyErr_Clear();
        return env->intern(env, "nil");
    }
    const char *s = PyUnicode_AsUTF8(repr);
    emacs_value result = env->make_string(env, s ? s : "", s ? (ptrdiff_t)strlen(s) : 0);
    Py_DECREF(repr);
    return result;
}

/// (eaf-macos-call-python METHOD ARG...) → nil
/// All args are passed as Python strings.
///
/// Called from the Emacs main thread.  We call Python directly (no dispatch)
/// so that @PostGui()-decorated EAF methods receive a same-thread signal and
/// execute via a Qt DirectConnection — meaning the call is fully synchronous
/// and the Qt event queue is never involved.
///
/// Main-thread sync bridge requests are serviced inline while this function is
/// active. Pre-caching still reduces re-entrant Emacs queries during startup.
static emacs_value
Fmacos_call_python(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    if (nargs < 1) return env->intern(env, "nil");

    NSString *method = extractNSString(env, args[0]);

    PyGILState_STATE gil = PyGILState_Ensure();

    PyObject *instance = get_eaf_instance();
    if (!instance) {
        PyGILState_Release(gil);
        return env->intern(env, "nil");
    }

    PyObject *py_args = PyTuple_New((Py_ssize_t)(nargs - 1));
    for (ptrdiff_t i = 1; i < nargs; i++) {
        NSString *s = extractNSString(env, args[i]);
        PyTuple_SET_ITEM(py_args, (Py_ssize_t)(i - 1),
                         PyUnicode_FromString(s.UTF8String));
    }

    emacs_env *prev_direct_env = gDirectBridgeEnv;
    gDirectBridgeEnv = env;

    PyObject *meth = PyObject_GetAttrString(instance, method.UTF8String);
    Py_DECREF(instance);
    emacs_value result = env->intern(env, "nil");
    if (meth) {
        PyObject *ret = PyObject_Call(meth, py_args, NULL);
        if (!ret) { NSLog(@"[eaf-macos] call-python: %@ raised", method); PyErr_Print(); }
        else {
            result = python_result_to_emacs(env, ret);
            Py_DECREF(ret);
        }
        Py_DECREF(meth);
    } else {
        NSLog(@"[eaf-macos] call-python: method %@ not found", method);
        PyErr_Clear();
    }
    gDirectBridgeEnv = prev_direct_env;
    Py_DECREF(py_args);
    PyGILState_Release(gil);
    return result;
}

/// (eaf-macos-alive-p) → t / nil
static emacs_value
Fmacos_alive_p(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    return env->intern(env, eaf_instance_ready() ? "t" : "nil");
}

// ══ Python startup ════════════════════════════════════════════════════════

static void start_python_on_appkit_main_thread(int width,
                                               int height,
                                               NSString *sourceDir,
                                               NSString *venvSite) {
    // ── Step 1: Py_Initialize (once) ──────────────────────────────────────
    if (!gPythonStarted) {
        Py_Initialize();
        PyEval_SaveThread();
        gPythonStarted = YES;
    }

    // ── Step 2: sys.path → QtWebEngine → QApplication → import eaf ───────
    // ORDER: QtWebEngineWidgets BEFORE QApplication;
    //        QApplication BEFORE import eaf (@PostGui QObject creation).
    PyGILState_STATE gil = PyGILState_Ensure();

    eaf_python_add_paths(sourceDir.UTF8String, venvSite.UTF8String);

    const char *boot =
        "import os\n"
        "import sys\n"
        "_eaf_flags = os.environ.get('QTWEBENGINE_CHROMIUM_FLAGS', '').split()\n"
        "for _eaf_flag in [\n"
        "    '--disable-web-security',\n"
        "    '--disable-background-timer-throttling',\n"
        "    '--disable-renderer-backgrounding',\n"
        "    '--disable-backgrounding-occluded-windows',\n"
        "]:\n"
        "    if _eaf_flag not in _eaf_flags:\n"
        "        _eaf_flags.append(_eaf_flag)\n"
        "os.environ['QTWEBENGINE_CHROMIUM_FLAGS'] = ' '.join(_eaf_flags)\n"
        "from PyQt6 import QtWebEngineWidgets as _eaf_web_dummy\n"
        "from PyQt6.QtWidgets import QApplication\n"
        "_eaf_qapp = QApplication.instance() or QApplication(sys.argv)\n"
        "_eaf_qapp.setApplicationName('eaf.py')\n";
    if (PyRun_SimpleString(boot) != 0) {
        NSLog(@"[eaf-macos] ERROR: boot script failed");
        PyErr_Print();
        gEAFStartInProgress = NO;
        PyGILState_Release(gil);
        return;
    }

    PyObject *mod = PyImport_ImportModule("eaf");
    if (!mod) {
        NSLog(@"[eaf-macos] ERROR: import eaf failed");
        PyErr_Print();
        gEAFStartInProgress = NO;
        PyGILState_Release(gil);
        return;
    }
    gEAFModule = mod;  // keep alive; Py_DECREF intentionally omitted

    // ── Step 3: launch EAF init on a Python background thread ─────────
    PyObject *startFn = PyObject_GetAttrString(mod, "eaf_start_embedded_thread");
    if (startFn) {
        PyObject *ret = PyObject_CallFunction(startFn, "ii", width, height);
        if (!ret) {
            NSLog(@"[eaf-macos] ERROR: eaf_start_embedded_thread failed");
            PyErr_Print();
            gEAFStartInProgress = NO;
        } else {
            gEAFStarted = YES;
            gEAFStartInProgress = NO;
            Py_DECREF(ret);
        }
        Py_DECREF(startFn);
    } else {
        NSLog(@"[eaf-macos] ERROR: eaf_start_embedded_thread not found");
        PyErr_Print();
        gEAFStartInProgress = NO;
    }

    PyGILState_Release(gil);
}

/// (eaf-macos-start-python W H SOURCE-DIR VENV-SITE) → nil
static emacs_value
Fstart_python(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    if (nargs != 4) return env->intern(env, "nil");

    intmax_t width  = env->extract_integer(env, args[0]);
    intmax_t height = env->extract_integer(env, args[1]);
    NSString *sourceDir = extractNSString(env, args[2]);
    NSString *venvSite  = extractNSString(env, args[3]);

    if (gEAFStarted || gEAFStartInProgress) {
        return env->intern(env, "nil");
    }
    gEAFStartInProgress = YES;

    int w = (int)width;
    int h = (int)height;
    NSString *sourceDirCopy = [sourceDir copy];
    NSString *venvSiteCopy = [venvSite copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            start_python_on_appkit_main_thread(w, h, sourceDirCopy, venvSiteCopy);
        }
    });

    return env->intern(env, "nil");
}

// ══ Per-view NSView state ═════════════════════════════════════════════════

@interface EAFViewState : NSObject
@property (nonatomic, copy)   NSString    *bufferId;
@property (nonatomic, copy)   NSString    *viewId;
@property (nonatomic, weak)   NSWindow    *hostWindow;
@property (nonatomic, strong) NSView      *containerView;
@property (nonatomic, strong) EAFHostView *hostView;
@end

@implementation EAFViewState
@end

static NSMutableDictionary *gRegistry;

static NSMutableDictionary *registry(void) {
    if (!gRegistry) gRegistry = [NSMutableDictionary dictionary];
    return gRegistry;
}

// ══ Helpers ═══════════════════════════════════════════════════════════════

static NSWindow *emacsWindow(void) {
    for (NSWindow *w in [NSApp windows])
        if (w.isKeyWindow) return w;
    for (NSWindow *w in [NSApp windows])
        if (!w.isMiniaturized && w.isVisible) return w;
    return [[NSApp windows] firstObject];
}

static inline BOOL onEmacsGuiThread(void) {
    if ([NSThread isMainThread]) {
        return YES;
    }

    NSString *threadName = [NSThread currentThread].name;
    return threadName && [threadName rangeOfString:@"lisp-main"].location != NSNotFound;
}

static inline void runOnMainSync(dispatch_block_t block) {
    if (onEmacsGuiThread()) {
        block();
        return;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        block();
        dispatch_semaphore_signal(sem);
    });
    CFRunLoopWakeUp(mainRunLoop);
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

static inline void runOnAppKitAsync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
        return;
    }

    dispatch_async(dispatch_get_main_queue(), block);
}

static inline void withDirectBridgeEnv(emacs_env *env, dispatch_block_t block) {
    emacs_env *prevDirectEnv = gDirectBridgeEnv;
    gDirectBridgeEnv = env;
    @try {
        block();
    } @finally {
        gDirectBridgeEnv = prevDirectEnv;
    }
}

static NSWindow *windowForWindowNumber(NSInteger windowNumber) {
    if (windowNumber > 0) {
        NSWindow *window = [NSApp windowWithWindowNumber:windowNumber];
        if (window) {
            return window;
        }
    }

    return nil;
}

static NSWindow *liveWindowForViewState(EAFViewState *state) {
    if (!state) {
        return nil;
    }

    NSWindow *window = state.hostWindow ?: state.containerView.window ?: state.hostView.window;
    if (window && window.contentView && !window.isMiniaturized && window.isVisible) {
        return window;
    }

    return nil;
}

static NSRect localTopRectToContentView(NSWindow *window, int x, int y, int w, int h) {
    if (!window || !window.contentView) {
        return NSZeroRect;
    }

    NSRect bounds = window.contentView.bounds;
    CGFloat localX = (CGFloat)x;
    CGFloat localY = NSMaxY(bounds) - (CGFloat)y - (CGFloat)h;
    return NSMakeRect(localX,
                      localY,
                      (CGFloat)w,
                      (CGFloat)h);
}

static NSRect clampContentRect(NSWindow *window, NSRect rect) {
    if (!window || !window.contentView) {
        return rect;
    }

    NSRect bounds = window.contentView.bounds;
    CGFloat minX = NSMinX(bounds);
    CGFloat minY = NSMinY(bounds);
    CGFloat maxX = NSMaxX(bounds) - rect.size.width;
    CGFloat maxY = NSMaxY(bounds) - rect.size.height;

    if (maxX < minX) {
        maxX = minX;
    }
    if (maxY < minY) {
        maxY = minY;
    }

    rect.origin.x = MIN(MAX(rect.origin.x, minX), maxX);
    rect.origin.y = MIN(MAX(rect.origin.y, minY), maxY);
    return rect;
}

static NSAutoresizingMaskOptions autoresizingMaskForContentFrame(NSView *contentView,
                                                                 NSRect frame) {
    if (!contentView) {
        return NSViewNotSizable;
    }

    NSRect bounds = contentView.bounds;
    CGFloat epsilon = 1.5;
    CGFloat left = NSMinX(frame) - NSMinX(bounds);
    CGFloat right = NSMaxX(bounds) - NSMaxX(frame);
    CGFloat top = NSMinY(frame) - NSMinY(bounds);
    CGFloat bottom = NSMaxY(bounds) - NSMaxY(frame);

    NSAutoresizingMaskOptions mask = NSViewNotSizable;

    if (left <= epsilon && right <= epsilon) {
        mask |= NSViewWidthSizable;
    } else if (left <= epsilon) {
        mask |= NSViewWidthSizable | NSViewMaxXMargin;
    } else if (right <= epsilon) {
        mask |= NSViewMinXMargin | NSViewWidthSizable;
    } else {
        mask |= NSViewMinXMargin | NSViewMaxXMargin;
    }

    if (top <= epsilon && bottom <= epsilon) {
        mask |= NSViewHeightSizable;
    } else if (top <= epsilon) {
        mask |= NSViewHeightSizable | NSViewMaxYMargin;
    } else if (bottom <= epsilon) {
        mask |= NSViewMinYMargin | NSViewHeightSizable;
    } else {
        mask |= NSViewMinYMargin | NSViewMaxYMargin;
    }

    return mask;
}

static BOOL rectNearlyEqual(NSRect lhs, NSRect rhs) {
    return fabs(lhs.origin.x - rhs.origin.x) < 0.5 &&
           fabs(lhs.origin.y - rhs.origin.y) < 0.5 &&
           fabs(lhs.size.width - rhs.size.width) < 0.5 &&
           fabs(lhs.size.height - rhs.size.height) < 0.5;
}

static NSWindow *windowForFrameHint(uintptr_t frameHandleHint,
                                    int frameWidth,
                                    int frameHeight,
                                    EAFViewState *existingState) {
    NSWindow *hintedWindow = liveWindowForViewState(existingState);
    if (!hintedWindow && frameHandleHint > 0 && frameHandleHint <= (uintptr_t)NSIntegerMax) {
        hintedWindow = windowForWindowNumber((NSInteger)frameHandleHint);
    }
    if (hintedWindow && hintedWindow.contentView && !hintedWindow.isMiniaturized && hintedWindow.isVisible) {
        return hintedWindow;
    }

    NSWindow *bestWindow = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (NSWindow *candidate in [NSApp windows]) {
        if (!candidate.contentView || candidate.isMiniaturized || !candidate.isVisible) {
            continue;
        }

        CGFloat widthPenalty = fabs(candidate.frame.size.width - (CGFloat)frameWidth);
        CGFloat heightPenalty = fabs(candidate.frame.size.height - (CGFloat)frameHeight);
        CGFloat score = -((widthPenalty + heightPenalty) * 10.0);
        if (candidate.isKeyWindow) {
            score += 100000.0;
        } else if (candidate.isMainWindow) {
            score += 50000.0;
        }
        if (!bestWindow || score > bestScore) {
            bestWindow = candidate;
            bestScore = score;
        }
    }

    if (bestWindow) {
        return bestWindow;
    }

    return emacsWindow();
}

static NSArray<NSString *> *registryKeysForBufferId(NSString *bufferId) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (!bufferId || bufferId.length == 0) {
        return keys;
    }

    for (NSString *key in registry()) {
        EAFViewState *state = registry()[key];
        if ([state.bufferId isEqualToString:bufferId]) {
            [keys addObject:key];
        }
    }

    return keys;
}

static NSWindow *windowForBufferId(NSString *bufferId) {
    if (!bufferId || bufferId.length == 0) {
        return nil;
    }

    NSWindow *fallback = nil;
    for (EAFViewState *state in [registry() objectEnumerator]) {
        if (![state.bufferId isEqualToString:bufferId]) {
            continue;
        }

        NSWindow *window = state.hostWindow ?: state.containerView.window ?: state.hostView.window;
        if (!fallback) {
            fallback = window;
        }
        if (window.isKeyWindow) {
            return window;
        }
    }

    return fallback;
}

static BOOL responderBelongsToEAFHost(NSResponder *responder, NSWindow *window) {
    if (!responder || ![responder isKindOfClass:[NSView class]]) {
        return NO;
    }

    NSView *view = (NSView *)responder;
    for (EAFViewState *state in [registry() objectEnumerator]) {
        if (state.hostWindow != window &&
            state.containerView.window != window &&
            state.hostView.window != window) {
            continue;
        }

        if ((state.containerView &&
             (view == state.containerView || [view isDescendantOf:state.containerView])) ||
            (state.hostView &&
             (view == state.hostView || [view isDescendantOf:state.hostView]))) {
            return YES;
        }
    }

    return NO;
}

static NSView *findFocusableEmacsView(NSView *root, NSWindow *window) {
    if (!root) {
        return nil;
    }

    if (!responderBelongsToEAFHost(root, window) && root.acceptsFirstResponder) {
        return root;
    }

    for (NSView *subview in root.subviews) {
        NSView *candidate = findFocusableEmacsView(subview, window);
        if (candidate) {
            return candidate;
        }
    }

    return nil;
}

static void activateEmacsWindowForBufferId(NSString *bufferId) {
    if (gEmacsShuttingDown) {
        return;
    }

    runOnMainSync(^{
        NSWindow *window = windowForBufferId(bufferId);
        if (!window) {
            window = emacsWindow();
        }
        if (!window) {
            return;
        }

        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];

        NSResponder *currentResponder = window.firstResponder;
        if (!currentResponder || responderBelongsToEAFHost(currentResponder, window)) {
            NSView *targetResponder = window.initialFirstResponder;
            if (!targetResponder ||
                responderBelongsToEAFHost(targetResponder, window) ||
                !targetResponder.acceptsFirstResponder) {
                targetResponder = findFocusableEmacsView(window.contentView, window);
            }

            if (targetResponder && targetResponder.acceptsFirstResponder) {
                [window makeFirstResponder:targetResponder];
            } else {
                [window makeFirstResponder:nil];
            }
        }
    });
}

static void releaseViewState(EAFViewState *state) {
    if (!state) {
        return;
    }

    state.hostView.onResize = nil;
    [state.hostView removeFromSuperview];
    [state.containerView removeFromSuperview];
    state.containerView = nil;
    state.hostView = nil;
    state.hostWindow = nil;
}

static void releaseAllViewStates(void) {
    NSMutableDictionary *viewRegistry = gRegistry;
    if (!viewRegistry || viewRegistry.count == 0) {
        gRegistry = nil;
        return;
    }

    NSArray<EAFViewState *> *states = [viewRegistry allValues];
    [viewRegistry removeAllObjects];
    gRegistry = nil;

    for (EAFViewState *state in states) {
        releaseViewState(state);
    }
}

static EAFViewState *ensureViewState(NSString *bufferId,
                                     NSString *viewId,
                                     NSWindow *window,
                                     NSRect frame) {
    NSMutableDictionary *viewRegistry = registry();
    EAFViewState *state = viewRegistry[viewId];
    BOOL needsRecreate = (state == nil ||
                          state.hostWindow != window ||
                          state.containerView.superview != window.contentView);

    if (needsRecreate) {
        if (!state) {
            state = [[EAFViewState alloc] init];
        } else {
            releaseViewState(state);
        }

        state.bufferId = bufferId;
        state.viewId = viewId;
        state.hostWindow = window;

        NSView *container = [[NSView alloc] initWithFrame:frame];
        container.autoresizingMask =
            autoresizingMaskForContentFrame(window.contentView, frame);
        container.wantsLayer = YES;
        container.layer.backgroundColor = NSColor.clearColor.CGColor;
        state.containerView = container;

        EAFHostView *hostView = [[EAFHostView alloc] initWithFrame:container.bounds];
        hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        hostView.wantsLayer = YES;
        hostView.layer.backgroundColor = NSColor.clearColor.CGColor;
        state.hostView = hostView;

        __weak EAFViewState *weakState = state;
        hostView.onResize = ^(int width, int height) {
            EAFViewState *strongState = weakState;
            if (!strongState || !strongState.hostView) {
                return;
            }

            uintptr_t hostWid = (uintptr_t)(__bridge void *)strongState.hostView;
            eaf_python_resize_view(strongState.bufferId, hostWid, width, height);
        };

        [state.containerView addSubview:state.hostView];
        [window.contentView addSubview:state.containerView];
        viewRegistry[viewId] = state;
    }

    state.bufferId = bufferId;
    state.viewId = viewId;
    state.hostWindow = window;
    state.containerView.autoresizingMask =
        autoresizingMaskForContentFrame(window.contentView, frame);
    if (!rectNearlyEqual(state.containerView.frame, frame)) {
        [state.containerView setFrame:frame];
    }
    if (!rectNearlyEqual(state.hostView.frame, state.containerView.bounds)) {
        [state.hostView setFrame:state.containerView.bounds];
    }
    return state;
}

// ══ NSView management functions ═══════════════════════════════════════════

/// (eaf-macos-update-views VIEW-SPECS) → nil
/// Each line uses the PyQt host layout:
/// BUFFER-ID<TAB>VIEW-ID<TAB>FRAME-WINDOW-ID<TAB>FRAME-W<TAB>FRAME-H<TAB>X<TAB>Y<TAB>W<TAB>H
static emacs_value
Fupdate_views(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    if (nargs != 1) return env->intern(env, "nil");
    if (gEmacsShuttingDown) return env->intern(env, "nil");

    NSString *viewSpecs = extractNSString(env, args[0]);
    runOnAppKitAsync(^{
        NSMutableDictionary *viewRegistry = registry();
        NSMutableSet<NSString *> *activeViewIds = [NSMutableSet set];
        NSMutableArray<NSString *> *pythonViewInfos = [NSMutableArray array];
        NSMutableArray<NSArray *> *pendingResizes = [NSMutableArray array];
        NSArray<NSString *> *lines = viewSpecs.length > 0
            ? [viewSpecs componentsSeparatedByString:@"\n"]
            : @[];

        if (lines.count > 0 && !eaf_instance_ready()) {
            return;
        }

        for (NSString *line in lines) {
            if (line.length == 0) {
                continue;
            }

            NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
            if (fields.count != 9) {
                continue;
            }

            NSString *bufferId = fields[0];
            NSString *viewId = fields[1];
            uintptr_t frameHandleHint = (uintptr_t)fields[2].longLongValue;
            int frameWidth = fields[3].intValue;
            int frameHeight = fields[4].intValue;
            int localX = fields[5].intValue;
            int localY = fields[6].intValue;
            int localW = fields[7].intValue;
            int localH = fields[8].intValue;

            if (frameWidth <= 0 || frameHeight <= 0 || localW <= 0 || localH <= 0) {
                continue;
            }

            EAFViewState *existingState = viewRegistry[viewId];
            NSWindow *window = windowForFrameHint(frameHandleHint, frameWidth, frameHeight, existingState);
            if (!window) {
                continue;
            }

            NSRect rawFrame = localTopRectToContentView(window, localX, localY, localW, localH);
            NSRect frame = clampContentRect(window, rawFrame);
            EAFViewState *state = ensureViewState(bufferId, viewId, window, frame);
            uintptr_t hostWid = (uintptr_t)(__bridge void *)state.hostView;

            [activeViewIds addObject:viewId];
            [pythonViewInfos addObject:[NSString stringWithFormat:@"%@:%llu:0:0:%d:%d",
                                        bufferId,
                                        (unsigned long long)hostWid,
                                        localW,
                                        localH]];
            [pendingResizes addObject:@[bufferId,
                                        @((unsigned long long)hostWid),
                                        @(localW),
                                        @(localH)]];
        }

        // update_views/native_resize_view can still hit bridge sync queries on
        // the Qt/AppKit thread (for example, a cache miss during View setup).
        // Service those inline while this Emacs call is active so the main
        // thread does not enqueue a sync bridge item and then deadlock waiting
        // for itself to drain the queue later.
        withDirectBridgeEnv(env, ^{
            eaf_python_update_views([pythonViewInfos componentsJoinedByString:@","]);

            for (NSArray *resizeInfo in pendingResizes) {
                NSString *bufferId = resizeInfo[0];
                uintptr_t hostWid = (uintptr_t)[resizeInfo[1] unsignedLongLongValue];
                int width = [resizeInfo[2] intValue];
                int height = [resizeInfo[3] intValue];
                eaf_python_resize_view(bufferId, hostWid, width, height);
            }
        });

        NSMutableArray<NSString *> *staleViewIds = [NSMutableArray array];
        for (NSString *viewId in viewRegistry) {
            if (![activeViewIds containsObject:viewId]) {
                [staleViewIds addObject:viewId];
            }
        }

        for (NSString *viewId in staleViewIds) {
            EAFViewState *state = viewRegistry[viewId];
            if (!state) {
                continue;
            }

            releaseViewState(state);
            [viewRegistry removeObjectForKey:viewId];
        }
    });

    return env->intern(env, "nil");
}

/// (eaf-macos-destroy-buffer-views BUFFER-ID) → nil
static emacs_value
Fdestroy_buffer_views(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    if (nargs != 1) return env->intern(env, "nil");
    if (gEmacsShuttingDown) return env->intern(env, "nil");
    NSString *bufferId = extractNSString(env, args[0]);
    NSArray<NSString *> *keys = registryKeysForBufferId(bufferId);
    if (keys.count > 0) {
        NSMutableArray<EAFViewState *> *states = [NSMutableArray array];
        for (NSString *key in keys) {
            EAFViewState *state = registry()[key];
            if (state) {
                [states addObject:state];
            }
            [registry() removeObjectForKey:key];
        }
        runOnAppKitAsync(^{
            for (EAFViewState *state in states) {
                releaseViewState(state);
            }
        });
    }
    return env->intern(env, "nil");
}

/// (eaf-macos-activate-emacs-window [BUFFER-ID]) → nil
static emacs_value
Factivate_emacs_window(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    if (gEmacsShuttingDown) {
        return env->intern(env, "nil");
    }

    NSString *bufferId = nil;
    if (nargs == 1) {
        bufferId = extractNSString(env, args[0]);
    }
    activateEmacsWindowForBufferId(bufferId);
    return env->intern(env, "nil");
}

/// (eaf-macos-shutdown) → nil
/// Detach all native host views before Emacs tears down AppKit state.
static emacs_value
Fshutdown(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
    gEmacsShuttingDown = YES;
    gDirectBridgeEnv = NULL;

    runOnMainSync(^{
        releaseAllViewStates();
    });
    clear_eaf_module_ref();
    gEAFStarted = NO;
    gEAFStartInProgress = NO;

    return env->intern(env, "nil");
}

// ══ Module registration ═══════════════════════════════════════════════════

static void bindFunction(emacs_env *env,
                         const char *name,
                         ptrdiff_t minArgs, ptrdiff_t maxArgs,
                         emacs_function fn,
                         const char *doc) {
    emacs_value func    = env->make_function(env, minArgs, maxArgs, fn, doc, NULL);
    emacs_value sym     = env->intern(env, name);
    emacs_value fset    = env->intern(env, "fset");
    emacs_value fargs[] = {sym, func};
    env->funcall(env, fset, 2, fargs);
}

int emacs_module_init(struct emacs_runtime *ert) {
    // Register the _eaf_bridge built-in module BEFORE any Py_Initialize call.
    PyImport_AppendInittab("_eaf_bridge", &PyInit__eaf_bridge);

    emacs_env *env = ert->get_environment(ert);

    bindFunction(env, "eaf-macos-start-python",  4, 4, Fstart_python,
                 "Start EAF Python engine in-process.\n"
                 "Args: WIDTH HEIGHT SOURCE-DIR VENV-SITE-PACKAGES\n"
                 "No EPC port needed: bridge replaces EPC for Python↔Emacs IPC.");

    bindFunction(env, "eaf-macos-alive-p",        0, 0, Fmacos_alive_p,
                 "Return t when the EAF Python engine is running in-process.");

    bindFunction(env, "eaf-macos-call-python",    1, emacs_variadic_function,
                 Fmacos_call_python,
                 "Call EAF Python method METHOD with string ARGS directly.\n"
                 "Replaces eaf-call-async/eaf-call-sync on macOS.");

    bindFunction(env, "eaf-macos-service-bridge", 0, 0, Fservice_bridge,
                 "Drain the Python→Emacs bridge work queue.\n"
                 "Called from Emacs' post-command-hook on the main thread.");

    bindFunction(env, "eaf-macos-update-views",   1, 1, Fupdate_views,
                 "Update all EAF host views from VIEW-SPECS using the PyQt-style macOS path.");

    bindFunction(env, "eaf-macos-destroy-buffer-views", 1, 1, Fdestroy_buffer_views,
                 "Remove all EAF NSViews for BUFFER-ID from Emacs windows.");

    bindFunction(env, "eaf-macos-activate-emacs-window", 0, 1, Factivate_emacs_window,
                 "Activate the current Emacs NSWindow and restore keyboard focus.\n"
                 "When BUFFER-ID is provided, prefer the NSWindow hosting that EAF view.");

    bindFunction(env, "eaf-macos-shutdown", 0, 0, Fshutdown,
                 "Detach native EAF host views before Emacs exits.");

    emacs_value provide  = env->intern(env, "provide");
    emacs_value feature  = env->intern(env, "eaf-macos-module");
    emacs_value pargs[]  = {feature};
    env->funcall(env, provide, 1, pargs);

    NSLog(@"[eaf-macos] module loaded");
    return 0;
}
