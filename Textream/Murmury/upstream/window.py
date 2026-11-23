"""Murmury floating window, adapted for the Textream presenter companion."""
from __future__ import annotations

import argparse
import html
import re
import sys
import threading
import time
from pathlib import Path, PurePosixPath

from PySide6.QtCore import QObject, QPoint, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QFont, QKeySequence, QShortcut
from PySide6.QtWidgets import (QApplication, QFrame, QHBoxLayout, QLabel, QLineEdit, QMenuBar, QPushButton,
                               QScrollArea, QSizeGrip, QVBoxLayout, QWidget)

from . import theme
from .chrome import AppearanceButton, TrafficLights

JOIN_SECONDS = 6.0  # a line this soon after the last one continues the same question

STYLE = """
#panel { background: $glass; border: 1px solid $panel_border; border-radius: 12px; }
QLabel { color: $text; }
#bar { color: $secondary; font-size: 11px; }
#heard { color: $secondary; font-size: 12px; border-left: 2px solid $accent; padding-left: 8px; }
#question { color: $text; font-size: 14px; font-weight: 600; }
#keys { color: $tertiary; font-size: 11px; }
QScrollArea, #cards { background: transparent; border: none; }
#card { background: $card; border: 1px solid $card_border; border-radius: 8px; }
#cardq { color: $secondary; font-size: 12px; font-weight: 400; border-left: 2px solid $quote_bar; padding-left: 8px; }
#carda { color: $text; font-size: 14px; }
#cardmeta { color: $tertiary; font-size: 11px; }
QLineEdit { background: $input; border: 1px solid $input_border; border-radius: 6px; color: $text; padding: 4px 8px; }
QPushButton { background: transparent; border: none; color: $secondary; font-size: 13px; padding: 0 4px; }
QPushButton:hover { color: $link; }
"""

REF = re.compile(r"\[([^\]]{1,60})\]\s*$")
SOURCE_LINK = re.compile(r"murmury-source:(\d+)\Z")


def source_index(reference: str, paths: list[Path]) -> int | None:
    """Resolve a citation only when its document is unambiguous."""
    if len(paths) == 1:
        return 0
    for index, path in enumerate(paths):
        name = PurePosixPath(str(path).replace("\\", "/")).name
        if reference.casefold().startswith(name.casefold()):
            boundary = reference[len(name):len(name) + 1]
            if not boundary or boundary in " ,:!#[":
                return index
    return None


MAX_LINES = 3  # fact lines a card shows under the SAY line: the answer style's limit, set at start
ANSWERED = threading.Event()  # set once a card is shown: the next setup screen may then ask for a star
FORMAT = "talking"  # the answer style's format: "script" lines show as one paragraph, the others as bullets


def card_lines(text: str) -> list[str]:
    """The lines a card shows: the SAY line and at most MAX_LINES facts.
    Closing remarks and stray text are dropped. Copy uses the same lines."""
    lines, say, facts = [], False, 0
    for line in text.splitlines():
        line = line.strip()
        if not line or not (line.upper().startswith("SAY:") or line[0] in "-•*"):
            continue
        if line.upper().startswith("SAY:"):
            if say:
                continue
            say = True
        else:
            if facts >= (MAX_LINES if say else MAX_LINES + 1):
                break
            facts += 1
        lines.append(line)
    return lines


def answer_html(text: str, source_paths: list[Path] | None = None) -> str:
    """The SAY line large and bold; the facts as bullets with their source as a small tag."""
    c = theme.palette()
    head, items = "", []
    for line in card_lines(text):
        if line.upper().startswith("SAY:"):
            head = f'<p style="font-size:15px; font-weight:600; color:{c['text']}; margin:0 0 6px 0;">{html.escape(line[4:].strip(), quote=False)}</p>'
            continue
        line = line.lstrip("-•* ").strip()
        ref = REF.search(line)
        body = html.escape(line[: ref.start()].strip() if ref else line)
        plain = html.unescape(body)
        label = re.match(r"^([A-Za-z0-9][\w /&'’-]{0,40}):\s", plain)
        rest = plain[label.end():] if label else plain
        # the one number of the line stands out, so the eye finds it first. quote=False: an apostrophe
        # escaped as &#x27; would put digits inside the text, and the number below would match them
        rest = html.escape(rest, quote=False)
        rest = re.sub(r"([€$£]?\d[\d.,]*\s?(?:%|×|(?:x|m|bn|k|million|billion)\b)?)", rf'<b style="color:{c["text"]};">\1</b>', rest, count=1)
        body = (f'<b style="color:{c["text"]};">{html.escape(label.group(1), quote=False)}:</b> ' if label else "") + rest
        index = source_index(ref.group(1), source_paths or []) if ref else None
        tag_text = (f'&nbsp;{html.escape(ref.group(1), quote=False)}&nbsp;' if ref else "")
        if index is not None:
            tag = (f' <a href="murmury-source:{index}" style="color:{c["link"]}; text-decoration:underline;">'
                   f'<span style="background:{c["tag_bg"]}; font-size:11px;">{tag_text}</span></a>')
        else:
            tag = (f' <span style="color:{c["tag_fg"]}; background:{c["tag_bg"]}; font-size:11px;">{tag_text}</span>'
                   if ref else "")
        items.append((body, tag))
    if FORMAT == "script":  # one paragraph, read on from the SAY line
        text = " ".join(f"{body}{'' if body.rstrip().endswith(('.', '!', '?')) else '.'}{tag}" for body, tag in items)
        return head + (f'<p style="margin:0; color:{c['text']}; line-height:140%;">{text}</p>' if items else "")
    rows = "".join(f'<li style="margin-bottom:4px; color:{c['text']};">{body}{tag}</li>' for body, tag in items)
    return head + (f'<ul style="margin-left:-20px; margin-top:0;">{rows}</ul>' if items else "")


def force_light_appearance() -> None:
    """Murmury is designed light; native controls would turn dark in Dark Mode on its white panels."""
    try:
        from AppKit import NSAppearance, NSApplication
        NSApplication.sharedApplication().setAppearance_(NSAppearance.appearanceNamed_("NSAppearanceNameAqua"))
    except Exception:
        pass


def _configure_macos(widget: QWidget, hide_from_capture: bool = True) -> bool:
    """Keep the window visible when another app is in front, on every Space and over full-screen apps,
    and (unless testing) out of screen sharing and screenshots. Returns whether it is hidden from capture."""
    try:
        import objc
        from AppKit import (NSFloatingWindowLevel, NSWindowCollectionBehaviorCanJoinAllSpaces,
                            NSWindowCollectionBehaviorFullScreenAuxiliary, NSWindowSharingNone,
                            NSWindowSharingReadOnly)

        window = objc.objc_object(c_void_p=int(widget.winId())).window()
        window.setHidesOnDeactivate_(False)  # a Qt tool window is a panel, which macOS hides on app switch
        window.setLevel_(NSFloatingWindowLevel)
        window.setCollectionBehavior_(NSWindowCollectionBehaviorCanJoinAllSpaces
                                      | NSWindowCollectionBehaviorFullScreenAuxiliary)
        window.setSharingType_(NSWindowSharingNone if hide_from_capture else NSWindowSharingReadOnly)
        return window.sharingType() == NSWindowSharingNone
    except Exception:
        return False


WDA_NONE = 0x0
WDA_EXCLUDEFROMCAPTURE = 0x11  # Windows 10 version 2004 and later


def _set_display_affinity(hwnd: int, flag: int) -> bool:
    """Call SetWindowDisplayAffinity on a window handle. False if Windows refuses (for example before 10 2004)."""
    import ctypes
    user32 = ctypes.windll.user32
    user32.SetWindowDisplayAffinity.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    user32.SetWindowDisplayAffinity.restype = ctypes.c_int
    return bool(user32.SetWindowDisplayAffinity(hwnd, flag))


def _configure_windows(widget: QWidget, hide_from_capture: bool = True) -> bool:
    """Exclude the window from screen capture on Windows. Returns whether it is hidden from capture."""
    try:
        flag = WDA_EXCLUDEFROMCAPTURE if hide_from_capture else WDA_NONE
        done = _set_display_affinity(int(widget.winId()), flag)
        return done and hide_from_capture
    except Exception:
        return False


def configure_native_window(widget: QWidget, hide_from_capture: bool = True) -> bool:
    """Set up the window for this platform and (unless testing) hide it from screen sharing and screenshots.
    Returns whether it is hidden from capture."""
    if sys.platform == "win32":
        return _configure_windows(widget, hide_from_capture)
    return _configure_macos(widget, hide_from_capture)


class Bridge(QObject):
    status = Signal(str)
    warning = Signal(str)
    heard = Signal(str)
    card = Signal(int, str)  # create or update the card for a question
    answer = Signal(int, str)  # the card's answer so far
    meta = Signal(int, str)  # the card's timing line
    timing = Signal(str)  # status bar after an answer
    hotkey = Signal(str)  # a global hotkey was pressed: "ask" or "clear"
    sources = Signal(object)  # selected document paths, used to resolve source tags


class Window(QWidget):
    def __init__(self, bridge: Bridge, ask):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint
                         | Qt.WindowType.Tool)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowTitle("Murmury")
        self.resize(430, 330)
        self.drag: QPoint | None = None
        self.ask = ask
        self.source_paths: list[Path] = []

        panel = QFrame(self, objectName="panel")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(panel)
        box = QVBoxLayout(panel)
        box.setContentsMargins(14, 10, 14, 8)
        box.setSpacing(8)

        top = QHBoxLayout()
        top.setSpacing(10)
        lights = TrafficLights()
        lights.close_clicked.connect(QApplication.quit)
        lights.minimize_clicked.connect(self.toggle_compact)
        lights.zoom_clicked.connect(self.toggle_zoom)
        top.addWidget(lights)
        self.bar = QLabel("Starting…", objectName="bar")
        top.addWidget(self.bar, 1)
        top.addWidget(AppearanceButton())
        box.addLayout(top)
        self.compact, self.zoomed, self.normal_size = False, False, None

        self.heard = QLabel("", objectName="heard", wordWrap=True)
        self.heard.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.cards: dict[int, tuple[QFrame, QLabel, QLabel, QLabel]] = {}
        self.plain: dict[int, str] = {}  # each card's answer as text, for Copy
        holder = QWidget(objectName="cards")
        self.stack = QVBoxLayout(holder)
        self.stack.setContentsMargins(0, 0, 4, 0)
        self.stack.setSpacing(8)
        self.stack.addStretch(1)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setWidget(holder)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.input = QLineEdit(placeholderText="Type a question and press Enter")
        self.input.hide()
        self.input.returnPressed.connect(self.ask_typed)
        keys = QHBoxLayout()
        keys.addWidget(QLabel("⌥Space ask · ⌥K clear · scroll for earlier answers", objectName="keys"), 1)
        copy_all = QPushButton("Copy all")
        copy_all.setCursor(Qt.CursorShape.PointingHandCursor)
        copy_all.clicked.connect(self.copy_all)
        keys.addWidget(copy_all)
        keys.addWidget(QSizeGrip(panel), 0, Qt.AlignmentFlag.AlignBottom | Qt.AlignmentFlag.AlignRight)
        box.addWidget(self.heard)
        box.addWidget(self.scroll, 1)
        box.addWidget(self.input)
        self.keys = QWidget()
        self.keys.setLayout(keys)
        keys.setContentsMargins(0, 0, 0, 0)
        box.addWidget(self.keys)
        self.apply_theme()
        theme.watch(self.apply_theme)

        # in-window shortcuts; main() turns one off once its global hotkey is registered, so a key never fires twice
        self.shortcuts = {"ask": QShortcut(QKeySequence("Alt+Space"), self, self.toggle_input),
                          "clear": QShortcut(QKeySequence("Alt+K"), self, self.clear)}
        bridge.hotkey.connect(self.on_hotkey)

        self.warning_text = ""
        bridge.status.connect(self.set_status)
        bridge.warning.connect(self.set_warning)
        bridge.heard.connect(lambda t: self.heard.setText(f"them: {t}"))
        bridge.card.connect(self.on_card)
        bridge.answer.connect(self.on_answer)
        bridge.meta.connect(self.on_meta)
        bridge.timing.connect(self.set_status)
        bridge.sources.connect(self.set_source_paths)

    def set_source_paths(self, paths: list[Path]) -> None:
        self.source_paths = [Path(path) for path in paths]

    def set_warning(self, warning: str) -> None:
        self.warning_text = warning
        if warning:
            self.bar.setText(f"{self.bar.text()} | {warning}")

    def set_status(self, status: str) -> None:
        if self.warning_text:
            status = f"{status} | {self.warning_text}"
        self.bar.setText(status)

    def toggle_compact(self) -> None:
        """Yellow: fold to the status bar only (a floating panel cannot go to the Dock); again to unfold."""
        self.compact = not self.compact
        for w in (self.heard, self.scroll, self.keys):
            w.setVisible(not self.compact)
        if self.compact:
            self.normal_size = self.size()
            self.setMinimumHeight(0)
            self.resize(self.width(), 44)
        elif self.normal_size:
            self.resize(self.normal_size)

    def toggle_zoom(self) -> None:
        """Green: grow to most of the screen height and a little wider; again to go back."""
        if self.compact:
            self.toggle_compact()
        screen = self.screen().availableGeometry()
        if not self.zoomed:
            self.normal_size = self.size()
            self.resize(max(self.width(), 520), int(screen.height() * 0.8))
            self.move(self.x(), screen.top() + int(screen.height() * 0.1))
        elif self.normal_size:
            self.resize(self.normal_size)
        self.zoomed = not self.zoomed

    # drag anywhere on the window
    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.drag = event.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, event):
        if self.drag is not None:
            self.move(event.globalPosition().toPoint() - self.drag)

    def mouseReleaseEvent(self, event):
        self.drag = None

    MAX_CARDS = 30  # older answers drop off; nothing is written to disk

    def apply_theme(self) -> None:
        self.setStyleSheet(theme.fill(STYLE))
        theme.refresh_native(self)
        for card, (_, _, label, _) in getattr(self, "cards", {}).items():  # answers carry inline colours
            if self.plain.get(card):
                label.setText(answer_html(self.plain[card], self.source_paths))

    def on_card(self, card: int, question: str) -> None:
        if card not in self.cards:
            frame = QFrame(objectName="card")
            inner = QVBoxLayout(frame)
            inner.setContentsMargins(10, 8, 10, 8)
            inner.setSpacing(4)
            q, a, meta = (QLabel("", objectName="cardq", wordWrap=True), QLabel("", objectName="carda", wordWrap=True),
                          QLabel("", objectName="cardmeta"))
            a.setTextFormat(Qt.TextFormat.RichText)
            for label in (q, a):  # text can be selected and copied
                label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            a.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction
                                      | Qt.TextInteractionFlag.TextSelectableByMouse)
            a.setOpenExternalLinks(False)
            a.linkActivated.connect(self.open_source)
            copy = QPushButton("Copy")
            copy.setCursor(Qt.CursorShape.PointingHandCursor)
            copy.clicked.connect(lambda _=False, c=card: self.copy_card(c))
            footer = QHBoxLayout()
            footer.addWidget(meta, 1)
            footer.addWidget(copy)
            inner.addWidget(q)
            inner.addSpacing(4)  # the question, quiet; then the answer, which is what the eye looks for
            inner.addWidget(a)
            inner.addLayout(footer)
            self.stack.insertWidget(0, frame)  # newest on top
            self.cards[card] = (frame, q, a, meta)
            for old in sorted(self.cards)[: max(0, len(self.cards) - self.MAX_CARDS)]:
                self.cards.pop(old)[0].deleteLater()
            self.scroll.verticalScrollBar().setValue(0)
        self.cards[card][1].setText(question)
        self.cards[card][2].setText("")

    def on_answer(self, card: int, text: str) -> None:
        if card in self.cards:
            self.cards[card][2].setText(answer_html(text, self.source_paths))
            self.plain[card] = text

    def open_source(self, link: str) -> None:
        """Open a selected source file without trusting a model-provided filesystem path."""
        match = SOURCE_LINK.fullmatch(link)
        if not match:
            return
        index = int(match.group(1))
        if index >= len(self.source_paths):
            return
        path = self.source_paths[index]
        if not path.is_file():
            self.set_status(f"Source file is no longer available: {path.name}")
            return
        if not QDesktopServices.openUrl(QUrl.fromLocalFile(str(path))):
            self.set_status(f"Could not open {path.name}")

    def copy_card(self, card: int) -> None:
        if card in self.cards:
            question = self.cards[card][1].text()
            shown = "\n".join(card_lines(self.plain.get(card, "")))
            QApplication.clipboard().setText(f"{question}\n{shown}".strip())
            self.cards[card][3].setText(self.cards[card][3].text().split(" · copied")[0] + " · copied")

    def copy_all(self) -> None:
        """Copy every card, oldest first, as Markdown: question as heading, answer lines as bullets."""
        if not self.cards:
            return
        parts = []
        for card in sorted(self.cards):
            question = self.cards[card][1].text().strip()
            lines = card_lines(self.plain.get(card, ""))
            if not question and not lines:
                continue
            md = f"## {question}" if question else ""
            bullets = "\n".join(f"- {line[4:].strip() if line.upper().startswith('SAY:') else line.lstrip('-•* ').strip()}"
                                for line in lines)
            if md and bullets:
                parts.append(f"{md}\n\n{bullets}")
            elif md:
                parts.append(md)
            elif bullets:
                parts.append(bullets)
        text = "\n\n".join(parts).strip()
        if text:
            QApplication.clipboard().setText(text)
            self.set_status("Copied all")

    def on_meta(self, card: int, text: str) -> None:
        if card in self.cards:
            self.cards[card][3].setText(text)

    def on_hotkey(self, name: str) -> None:
        """A global hotkey, pressed while any app has focus. Runs on the main thread (it arrives as a Qt signal)."""
        if name == "ask":
            if not self.input.isVisible():  # opening the box: the typing has to land here, not in the call app
                bring_to_front()
                self.raise_()
            self.toggle_input()
        elif name == "clear":
            self.clear()

    def toggle_input(self) -> None:
        self.input.setVisible(not self.input.isVisible())
        if self.input.isVisible():
            self.activateWindow()
            self.input.setFocus()

    def ask_typed(self) -> None:
        text = self.input.text().strip()
        if text:
            self.input.clear()
            self.input.hide()
            self.ask(text)

    def clear(self) -> None:
        self.heard.setText("")
        for frame, *_ in self.cards.values():
            frame.deleteLater()
        self.cards.clear()
