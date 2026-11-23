"""Murmury overlay for a presenter session. JSON lines on inherited pipes only."""
import html
import json
import os
import sys
import threading

from PySide6.QtCore import Qt, Signal, QObject, QSettings, QPoint
from PySide6.QtWidgets import QApplication, QCheckBox, QComboBox, QHBoxLayout, QPushButton, QLabel
from upstream.window import Window, Bridge, configure_native_window, answer_html
from upstream import theme


class PresenterPanel(Window):
    def __init__(self, emit):
        self.bridge = Bridge()
        self.emit = emit
        self.context = ""
        self.state = {}
        self.details_shown = False
        super().__init__(self.bridge, self.submit_text)
        self.setWindowTitle("Xpresentext · 现场问答")
        self.input.setPlaceholderText("输入问题，回车提交")
        self.input.show()
        self.input.returnPressed.disconnect()
        self.input.returnPressed.connect(self.send_input)
        self.keys.hide()
        self.heard.setTextFormat(Qt.TextFormat.PlainText)
        self.bar.setTextFormat(Qt.TextFormat.PlainText)
        self.resize(510, 395)
        self.correcting = None
        box = self.keys.parentWidget().layout()
        controls = QHBoxLayout()
        self.mode = QComboBox()
        self.mode.addItems(["现场复述", "会议声音"])
        self.mode.currentIndexChanged.connect(lambda _: self.action("stop"))
        self.locale = QComboBox()
        self.locale.addItems(["中文", "English"])
        preferences = QSettings("Textream", "Murmury")
        self.locale.setCurrentIndex(1 if preferences.value("repeatLanguage") == "en-US" else 0)
        self.locale.currentIndexChanged.connect(lambda index: preferences.setValue("repeatLanguage", "en-US" if index else "zh-CN"))
        self.listen = QPushButton("听题")
        self.listen.clicked.connect(self.toggle_listen)
        self.follow = QCheckBox("追问")
        self.follow.toggled.connect(lambda checked: self.action("follow", follow=checked))
        for item in (self.mode, self.locale, self.listen, self.follow):
            controls.addWidget(item)
        box.addLayout(controls)
        options = QHBoxLayout()
        self.correct = QPushButton("修改转写")
        self.correct.clicked.connect(self.edit_transcript)
        self.more = QPushButton("深入解答")
        self.more.clicked.connect(self.toggle_details)
        self.retry = QPushButton("重试")
        self.retry.clicked.connect(lambda: self.action("retry"))
        self.use_heard = QPushButton("回答这句")
        self.use_heard.clicked.connect(lambda: self.action("useHeard", follow=self.follow.isChecked()))
        self.cancel = QPushButton("取消听题")
        self.cancel.clicked.connect(lambda: self.action("stop"))
        self.advanced = advanced = QPushButton("更多选项…")
        advanced.clicked.connect(lambda: self.action("advanced"))
        for item in (self.correct, self.more, self.retry, self.use_heard, self.cancel, advanced):
            options.addWidget(item)
        box.addLayout(options)
        self.correct.hide()
        self.more.hide()
        self.retry.hide()
        self.use_heard.hide()
        self.cancel.hide()

    def action(self, action, **values):
        if self.context:
            self.emit(dict(action=action, context=self.context, **values))

    def toggle_listen(self):
        if self.state.get("listening"):
            self.action("stop" if self.mode.currentIndex() else "finish")
        else:
            self.action("meeting" if self.mode.currentIndex() else "microphone",
                        language="en-US" if self.locale.currentIndex() else "zh-CN", follow=self.follow.isChecked())

    def edit_transcript(self):
        self.correcting = self.state.get("transcriptID")
        self.input.setText(self.state.get("question", ""))
        self.input.show()
        self.input.setFocus()

    def send_input(self):
        text = self.input.text().strip()
        if text:
            self.submit_text(text)
            self.input.clear()

    def submit_text(self, text):
        self.action("correct" if self.correcting else "ask", text=text, id=self.correcting or "",
                    follow=self.follow.isChecked())
        self.correcting = None

    def open_source(self, link):
        if link.startswith("cite:") and link[5:].isdigit():
            index = int(link[5:])
            sources = self.state.get("sources", [])
            if index < len(sources):
                self.action("preview", id=sources[index]["id"])

    def toggle_details(self):
        self.details_shown = not self.details_shown
        self.render_card()

    def render_card(self):
        s = self.state
        if 1 not in self.cards:
            return
        body = ([f'SAY: {s["short"]}'] if s.get("short") else [])
        body.extend("- " + line for line in s.get("bullets", []))
        self.plain[1] = "\n".join(body)
        markup = answer_html(self.plain[1])
        if s.get("kind"):
            markup += "<p>" + html.escape(s["kind"]) + "</p>"
        for i, source in enumerate(s.get("sources", [])):
            markup += f'<p><a href="cite:{i}">{html.escape(source["label"])}</a></p>'
        if self.details_shown:
            markup += "".join("<p>" + html.escape(line) + "</p>" for line in s.get("details", []))
        self.cards[1][2].setText(markup)
        self.more.setText("收起解答" if self.details_shown else "深入解答")

    def apply_theme(self):
        super().apply_theme()
        if self.state:
            self.render_card()

    def receive(self, s):
        if s["type"] == "focus":
            self.show()
            self.raise_()
            self.activateWindow()
            return
        if s["type"] != "state":
            return
        if self.context != s["context"] or self.state.get("question") != s.get("question"):
            self.details_shown = False
        if self.context != s["context"]:
            self.clear()
            self.plain.clear()
            self.input.clear()
            self.follow.setChecked(False)
            self.correcting = None
        if self.correcting and self.correcting != s.get("transcriptID"):
            self.correcting = None
            self.input.clear()
        self.context, self.state = s["context"], s
        self.bar.setText(" · ".join(filter(None, [s.get("title"), s.get("status")])))
        self.heard.setText(s.get("heard", ""))
        self.listen.setText(("停止会议收音" if self.mode.currentIndex() else "立即提交") if s.get("listening") else "听题")
        self.follow.setEnabled(bool(s.get("canFollow")))
        self.correct.setVisible(bool(s.get("transcriptID")))
        self.more.setVisible(bool(s.get("details")))
        self.retry.setVisible(bool(s.get("failed")))
        self.use_heard.setVisible(bool(s.get("canUseHeard")))
        self.cancel.setVisible(bool(s.get("listening")) and self.mode.currentIndex() == 0)
        self.advanced.setEnabled(not s.get("listening", False))
        if q := s.get("question"):
            if 1 not in self.cards:
                self.on_card(1, "")
                self.cards[1][1].setTextFormat(Qt.TextFormat.PlainText)
            self.cards[1][1].setText(q)
            self.render_card()
        elif self.cards:
            self.clear()
            self.plain.clear()


def main():
    app = QApplication(sys.argv)
    class Inbox(QObject):
        received = Signal(dict)
        closed = Signal()
    inbox = Inbox()
    panel = PresenterPanel(lambda event: print(json.dumps(event), flush=True))
    inbox.received.connect(panel.receive)
    inbox.closed.connect(app.quit)
    def read():
        try:
            with os.fdopen(os.dup(0), "rb") as stream:
                for line in stream:
                    inbox.received.emit(json.loads(line))
        finally:
            inbox.closed.emit()
    threading.Thread(target=read, daemon=True).start()
    if app.platformName() == "cocoa":
        prefs = QSettings("Textream", "Murmury")
        saved = prefs.value("panelGeometry")
        if not saved or not panel.restoreGeometry(saved):
            area = app.primaryScreen().availableGeometry()
            panel.move(area.topRight() - QPoint(panel.width() + 16, -20))
        app.aboutToQuit.connect(lambda: prefs.setValue("panelGeometry", panel.saveGeometry()))
    panel.show()
    if app.platformName() == "cocoa":
        configure_native_window(panel)
    print(json.dumps({"action": "ready"}), flush=True)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
