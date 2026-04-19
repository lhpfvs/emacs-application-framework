#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Copyright (C) 2018 Andy Stewart
#
# Author:     Andy Stewart <lazycat.manatee@gmail.com>
# Maintainer: Andy Stewart <lazycat.manatee@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

import platform
import sys

from core.utils import current_desktop, eval_in_emacs, focus_emacs_buffer, get_emacs_func_cache_result, get_emacs_var
from PyQt6.QtCore import QEvent, QPoint, QTimer, Qt
from PyQt6.QtGui import QBrush, QPainter, QWindow
from PyQt6.QtWidgets import QApplication, QFrame, QGraphicsView, QVBoxLayout, QWidget

IS_DARWIN = sys.platform == "darwin"
IS_WINDOWS = sys.platform == "win32"
IS_MAC_PORT = IS_DARWIN and bool(get_emacs_func_cache_result("eaf--mac-port-p", []))

if current_desktop in ["sway", "Hyprland"] and get_emacs_func_cache_result("eaf-emacs-running-in-wayland-native", []):
    global reinput

    import subprocess

    build_dir = get_emacs_var("eaf-build-dir")
    reinput_file = build_dir + "reinput/reinput"
    pid = get_emacs_func_cache_result("emacs-pid", [])
    reinput = subprocess.Popen(f"{reinput_file} {pid}", stdin=subprocess.PIPE, shell=True)


def focus():
    reinput.stdin.write("1\n".encode("utf-8"))
    reinput.stdin.flush()


def lose_focus():
    reinput.stdin.write("0\n".encode("utf-8"))
    reinput.stdin.flush()


class View(QWidget):

    def __init__(self, buffer, view_info):

        super(View, self).__init__()

        self.buffer = buffer

        if get_emacs_func_cache_result("eaf-emacs-running-in-wayland-native", []):
            self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.WindowOverridesSystemGestures | Qt.WindowType.BypassWindowManagerHint)
        elif get_emacs_func_cache_result("eaf-emacs-not-use-reparent-technology", []):
            self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.NoDropShadowWindowHint)
        else:
            self.setWindowFlags(Qt.WindowType.FramelessWindowHint)

        if IS_DARWIN:
            self.setAttribute(Qt.WidgetAttribute.WA_NativeWindow, True)
            self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
            self.setAttribute(Qt.WidgetAttribute.WA_MacShowFocusRect, False)
            self.setWindowFlag(Qt.WindowType.WindowDoesNotAcceptFocus, True)
            self.setFocusPolicy(Qt.FocusPolicy.NoFocus)

        if IS_DARWIN:
            self.is_member_of_focus_fix_wms = False
        else:
            self.is_member_of_focus_fix_wms = get_emacs_var("eaf-is-member-of-focus-fix-wms")

        self.setAttribute(Qt.WidgetAttribute.WA_X11DoNotAcceptFocus, True)
        self.setContentsMargins(0, 0, 0, 0)
        self.installEventFilter(self)

        self.last_event_type = None
        self.view_info = view_info
        (self.buffer_id, self.emacs_xid, self.x, self.y, self.width, self.height) = view_info.split(":")
        self.x = int(self.x)
        self.y = int(self.y)
        self.width = int(self.width)
        self.height = int(self.height)
        self._requested_width = self.width
        self._requested_height = self.height
        self._host_window = None
        self._did_reparent = False
        self._reparent_in_progress = False

        self.layout = QVBoxLayout(self)
        self.layout.setSpacing(0)
        self.layout.setContentsMargins(0, 0, 0, 0)
        self.graphics_view = QGraphicsView(buffer, self)

        self.graphics_view.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.graphics_view.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.graphics_view.setRenderHints(QPainter.RenderHint.Antialiasing | QPainter.RenderHint.SmoothPixmapTransform | QPainter.RenderHint.TextAntialiasing)
        self.graphics_view.setFrameStyle(QFrame.Shape.NoFrame)
        self.graphics_view.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
        self.graphics_view.setBackgroundBrush(QBrush(buffer.background_color))

        self.layout.addWidget(self.graphics_view)

        self.show()
        self.resize(self._requested_width, self._requested_height)

        self.buffer.aspect_ratio_change.connect(self.adjust_aspect_ratio)

        self.locate()

    def resizeEvent(self, event):
        self.width = event.size().width()
        self.height = event.size().height()

        if self.buffer.fit_to_view:
            self.adjust_aspect_ratio()

        if self.buffer.fit_to_view:
            if IS_MAC_PORT:
                if not event.oldSize().isValid():
                    self._fit_buffer_to_view()
            elif event.oldSize().isValid() or IS_DARWIN:
                self._fit_buffer_to_view()

        QWidget.resizeEvent(self, event)

    def update_view_info(self, view_info):
        if view_info == self.view_info:
            return

        old_host = self.emacs_xid
        old_width = self.width
        old_height = self.height
        self.view_info = view_info
        (self.buffer_id, self.emacs_xid, self.x, self.y, self.width, self.height) = view_info.split(":")
        self.x = int(self.x)
        self.y = int(self.y)
        self.width = int(self.width)
        self.height = int(self.height)
        self._requested_width = self.width
        self._requested_height = self.height
        host_changed = self.emacs_xid != old_host
        size_changed = self.width != old_width or self.height != old_height

        if host_changed:
            self._host_window = None
            self._did_reparent = False

        # On mac-port, the embedded NSView now resizes natively with its host.
        # Replaying QWidget.resize() and QWindow.setParent() for every geometry
        # sample fights that native path and makes live resize jumpy.
        if not (IS_MAC_PORT and self._did_reparent and not host_changed):
            self.resize(self.width, self.height)
        elif size_changed and self.buffer.fit_to_view:
            QTimer.singleShot(0, self._fit_buffer_to_view)

        if IS_DARWIN and (host_changed or not self._did_reparent):
            self.reparent()

    def _sync_embedded_geometry(self):
        if IS_DARWIN:
            return

        qwindow = self.windowHandle()
        if qwindow is None:
            return

        qwindow.setGeometry(0, 0, self.width, self.height)

    def _schedule_embedded_attach_retries(self):
        if not IS_DARWIN:
            return

        if self.buffer.fit_to_view:
            if IS_MAC_PORT:
                self._fit_buffer_to_view()
            else:
                QTimer.singleShot(0, self._fit_buffer_to_view)

    def adjust_aspect_ratio(self):
        widget_width = self.width
        widget_height = self.height

        if self.buffer.aspect_ratio == 0:
            self.buffer.buffer_widget.resize(self.width, self.height)
            self.layout.setContentsMargins(0, 0, 0, 0)
        else:
            view_height = widget_height * (1 - 2 * self.buffer.vertical_padding_ratio)
            view_width = view_height * self.buffer.aspect_ratio
            horizontal_padding = (widget_width - view_width) / 2
            vertical_padding = self.buffer.vertical_padding_ratio * widget_height

            self.buffer.buffer_widget.resize(int(view_width), int(view_height))
            self.layout.setContentsMargins(int(horizontal_padding), int(vertical_padding), int(horizontal_padding), int(vertical_padding))

        self.buffer.setSceneRect(0, 0, self.buffer.buffer_widget.width(), self.buffer.buffer_widget.height())

    def _fit_buffer_to_view(self):
        self.graphics_view.resetTransform()

        if self.buffer.aspect_ratio == 0:
            return

        self.graphics_view.fitInView(self.graphics_view.scene().sceneRect(), Qt.AspectRatioMode.KeepAspectRatio)

    def is_switch_from_other_application(self, event):
        return (
            (event.type() in [QEvent.Type.ShortcutOverride]) or
            ((not self.is_member_of_focus_fix_wms) and
             (self.last_event_type not in [QEvent.Type.Resize, QEvent.Type.WinIdChange, QEvent.Type.Leave, QEvent.Type.UpdateRequest]) and
             (event.type() in [QEvent.Type.Enter])) or
            ((not self.is_member_of_focus_fix_wms) and
             (self.last_event_type is QEvent.Type.UpdateRequest) and
             (event.type() is QEvent.Type.KeyRelease)))

    def eventFilter(self, obj, event):
        event_type = event.type()

        if current_desktop in ["sway", "Hyprland"] and get_emacs_func_cache_result("eaf-emacs-running-in-wayland-native", []):
            if event_type == QEvent.Type.WindowActivate:
                focus()
            elif event_type == QEvent.Type.WindowDeactivate:
                lose_focus()

        if self.is_switch_from_other_application(event):
            eval_in_emacs("eaf-activate-emacs-window", [self.buffer_id])

        focus_event_types = [QEvent.Type.MouseButtonPress, QEvent.Type.MouseButtonRelease, QEvent.Type.MouseButtonDblClick]
        if platform.system() != "Darwin":
            focus_event_types += [QEvent.Type.Wheel]

        self.last_event_type = event.type()

        if event.type() in focus_event_types:
            focus_emacs_buffer(self.buffer_id)
            return True

        return False

    def showEvent(self, event):
        self.reparent()

        if IS_WINDOWS:
            eval_in_emacs("eaf-activate-emacs-window", [])
        elif IS_MAC_PORT:
            eval_in_emacs("eaf-activate-emacs-window", [self.buffer_id])

        self.graphics_view.verticalScrollBar().setValue(0)
        self.graphics_view.horizontalScrollBar().setValue(0)

        self._schedule_embedded_attach_retries()

        QWidget.showEvent(self, event)

    def _detach_embedded_window(self):
        qwindow = self.windowHandle()
        if qwindow is None:
            return

        try:
            qwindow.hide()
        except Exception:
            pass

        try:
            qwindow.setParent(None)
        except Exception:
            pass

    def reparent(self):
        qwindow = self.windowHandle()

        if IS_DARWIN:
            if qwindow is None:
                self.winId()
                qwindow = self.windowHandle()

            if qwindow is None or self._reparent_in_progress:
                return

            self._reparent_in_progress = True
            try:
                if self._host_window is None:
                    self._host_window = QWindow.fromWinId(int(self.emacs_xid))  # type: ignore

                if qwindow.parent() is not self._host_window:
                    qwindow.setParent(self._host_window)
                if not self._did_reparent:
                    self._did_reparent = True
                    QTimer.singleShot(0, qwindow.show)

                qwindow.requestUpdate()
            finally:
                self._reparent_in_progress = False
        else:
            if not get_emacs_func_cache_result("eaf-emacs-not-use-reparent-technology", []):
                qwindow.setParent(QWindow.fromWinId(int(self.emacs_xid)))  # type: ignore
            qwindow.setPosition(QPoint(self.x, self.y))

    def try_show_top_view(self):
        if get_emacs_func_cache_result("eaf-emacs-not-use-reparent-technology", []):
            self.setWindowFlag(Qt.WindowType.WindowStaysOnTopHint, True)
            self.show()

    def try_hide_top_view(self):
        if get_emacs_func_cache_result("eaf-emacs-not-use-reparent-technology", []):
            self.setWindowFlag(Qt.WindowType.WindowStaysOnTopHint, False)
            self.hide()

    def destroy_view(self):
        if IS_DARWIN:
            self._detach_embedded_window()
        self.destroy()

    def screen_shot(self):
        return self.grab()

    def locate(self):
        if not get_emacs_func_cache_result("eaf-emacs-running-in-wayland-native", []):
            return

        title = f"eaf.py-{self.x}-{self.y}"
        if current_desktop == "Hyprland":
            import subprocess

            subprocess.Popen(f"hyprctl --batch 'keyword windowrule float,title:^{title}$;"
                             f"keyword windowrule move {self.x} {self.y},title:^{title}$'", shell=True)
            self.setWindowTitle(title)
        elif current_desktop == "sway" and get_emacs_func_cache_result("eaf-emacs-not-use-reparent-technology", []):
            import subprocess

            subprocess.Popen(f"swaymsg 'for_window [title={title}] floating enable;"
                             f"for_window [title={title}] move position {self.x} {self.y}'", shell=True)
            self.setWindowTitle(title)
