import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Ollama Chat: a bar icon that opens a chat panel for testing an Ollama server.
// Model picker from /api/tags, streamed replies from /api/chat (via curl),
// optional thinking, per-reply speed stats, and attachments (Ctrl+V / Super+V
// pastes an image or copied files, + opens the file chooser; images go to the
// model's vision input, text files and PDFs into the message).
//
// The panel is its own layer-shell window rather than a KeyboardPanel, so it
// stays open while other windows are used; the bar icon (or Esc) closes it.
// Host, last-used model and the Think toggle live in ~/.config/ollama-chat/state.json.
BarWidget {
  id: root
  moduleName: "jim.ollama-chat"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string defaultHost: "http://192.168.2.61:11434"
  readonly property string stateDir: Quickshell.env("HOME") + "/.config/ollama-chat"
  readonly property string binDir: Qt.resolvedUrl("bin").toString().replace(/^file:\/\//, "")
  readonly property int pingSeconds: 30

  // Sent as a hidden first message so the model knows where it runs (models can't know this
  // themselves and tend to claim they are in the cloud). Override with "systemPrompt" in
  // state.json ("" turns it off); {model}, {size}, {quant} and {host} are filled in.
  readonly property string defaultSystemPrompt:
    "Facts about you: you are {model} ({size} parameters, {quant}), an open model running locally through " +
    "Ollama on the user's Mac mini ({host}) on their home network, not in the cloud. If the user asks " +
    "anything about you (who or what you are, \"tell me about yourself\", where or how you run), always " +
    "mention which model you are and that you run on their Mac mini, in your own words and talking to them " +
    "as \"you\" (e.g. \"your Mac mini\"). Don't bring this up otherwise; just be a helpful, concise assistant."

  property bool opened: false
  property var appState: ({})
  readonly property string host: String(appState.host || defaultHost).replace(/\/+$/, "")
  readonly property string hostLabel: host.replace(/^https?:\/\//, "")
  property bool online: false
  property bool pinged: false
  property string serverVersion: ""
  property var models: []
  property var loadedModels: []
  property bool pickerOpen: false
  property var attachments: []
  property string stats: ""
  // API-side conversation, index-aligned with chatModel (the display side)
  property var history: []
  property int liveIndex: -1

  readonly property var currentModel: {
    for (var i = 0; i < models.length; i++)
      if (models[i].name === appState.model) return models[i]
    return null
  }
  readonly property var capabilities: currentModel ? (currentModel.capabilities || []) : []
  readonly property bool canThink: capabilities.indexOf("thinking") >= 0
  readonly property bool busy: chatProc.running

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(Color.popups.text, 1.6)

  // ------------------------------------------------------------------ state

  function setStateKey(key, value) {
    var s = Object.assign({}, appState)
    s[key] = value
    appState = s
    stateFile.setText(JSON.stringify(s, null, 2) + "\n")
  }

  Process {
    running: true
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    printErrors: false
    onLoaded: {
      try { root.appState = JSON.parse(text()) } catch (e) { root.appState = {} }
      root.refreshModels()
    }
    onLoadFailed: root.refreshModels()
  }

  // ------------------------------------------------------------------ server

  component JsonFetch: Process {
    id: fetch
    property var callback: null
    function get(url, timeout, cb) {
      if (running) return
      callback = cb
      command = ["curl", "-fsS", "--max-time", String(timeout), url]
      running = true
    }
    stdout: StdioCollector {
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(text) } catch (e) {}
        if (fetch.callback) fetch.callback(data)
      }
    }
  }

  JsonFetch { id: versionFetch }
  JsonFetch { id: tagsFetch }
  JsonFetch { id: psFetch }

  function ping() {
    versionFetch.get(host + "/api/version", 4, function(d) {
      root.pinged = true
      root.online = !!(d && d.version)
      root.serverVersion = d && d.version && d.version !== "0.0.0" ? d.version : ""
    })
  }

  function refreshModels() {
    tagsFetch.get(host + "/api/tags", 5, function(tags) {
      if (!tags) {
        root.pinged = true
        root.online = false
        return
      }
      var list = (tags.models || []).slice().sort(function(a, b) { return a.name.localeCompare(b.name) })
      root.models = list
      var known = list.some(function(m) { return m.name === root.appState.model })
      if (!known && list.length) root.setStateKey("model", list[0].name)
      psFetch.get(root.host + "/api/ps", 5, function(ps) {
        root.loadedModels = ((ps && ps.models) || []).map(function(m) { return m.name })
      })
      root.ping()
    })
  }

  Timer {
    interval: root.pingSeconds * 1000
    running: true
    repeat: true
    onTriggered: root.ping()
  }

  function formatSize(bytes) {
    var gb = Number(bytes) / Math.pow(1024, 3)
    return gb >= 1 ? gb.toFixed(1) + " GB" : Math.round(gb * 1024) + " MB"
  }

  function seconds(ns) {
    return (Number(ns) / 1e9).toFixed(ns < 1e10 ? 2 : 1) + "s"
  }

  // Ollama's final "done" chunk carries the timings (all in nanoseconds).
  function formatStats(d, firstTokenMs) {
    var parts = []
    if (d.eval_count) {
      var tps = d.eval_duration ? d.eval_count / (d.eval_duration / 1e9) : 0
      parts.push(d.eval_count + " tok @ " + tps.toFixed(1) + " tok/s")
    }
    if (d.prompt_eval_count) parts.push("prompt " + d.prompt_eval_count + " tok " + seconds(d.prompt_eval_duration || 0))
    if (firstTokenMs >= 0) parts.push("first " + (firstTokenMs / 1000).toFixed(2) + "s")
    if (d.load_duration > 2e8) parts.push("load " + seconds(d.load_duration))
    if (d.total_duration) parts.push("total " + seconds(d.total_duration))
    return parts.join(" · ")
  }

  function systemPrompt() {
    var template = appState.systemPrompt !== undefined && appState.systemPrompt !== null
      ? String(appState.systemPrompt) : defaultSystemPrompt
    var details = currentModel ? (currentModel.details || {}) : {}
    var values = {
      model: appState.model,
      size: details.parameter_size || "unknown",
      quant: details.quantization_level || "unknown",
      host: hostLabel.replace(/:\d+$/, "")
    }
    return template.replace(/\{(\w+)\}/g, function(match, key) {
      return key in values ? String(values[key]) : match
    }).trim()
  }

  // ------------------------------------------------------------------ chat

  ListModel { id: chatModel }

  function send() {
    var text = input.text.trim()
    var atts = attachments
    if ((!text && !atts.length) || busy) return
    var images = atts.filter(function(a) { return a.kind === "image" })
    if (images.length && models.length && capabilities.indexOf("vision") < 0) {
      stats = appState.model + " can't see images; pick a vision model"
      return
    }
    if (!appState.model) {
      refreshModels()
      stats = "No model selected"
      return
    }
    if (!text) text = images.length ? "Describe this image." : "Summarize this."
    input.text = ""
    attachments = []

    // Text files ride along in the message; images go in Ollama's images field (kept for later turns).
    var content = text
    atts.forEach(function(a) { if (a.kind === "text") content += "\n\n--- " + a.name + " ---\n" + a.text })
    history.push({ role: "user", content: content, images: images.map(function(a) { return a.b64 }) })
    chatModel.append({ role: "user", body: text, thinking: "", files: atts.map(function(a) { return a.name }).join(" · "), error: false })
    history.push({ role: "assistant", content: "", thinking: "" })
    chatModel.append({ role: "assistant", body: "", thinking: "", files: "", error: false })
    liveIndex = chatModel.count - 1

    var messages = []
    var system = systemPrompt()
    if (system) messages.push({ role: "system", content: system })
    for (var i = 0; i < history.length - 1; i++) {
      var m = history[i]
      if (m.error) continue
      var out = { role: m.role, content: m.content }
      if (m.images && m.images.length) out.images = m.images
      messages.push(out)
    }
    var body = { model: appState.model, messages: messages, stream: true }
    if (canThink) body.think = !!appState.think

    chatProc.body = JSON.stringify(body)
    chatProc.model = appState.model
    chatProc.startedAt = Date.now()
    chatProc.firstTokenMs = -1
    chatProc.done = null
    chatProc.stopped = false
    chatProc.errorText = ""
    chatProc.command = ["curl", "-sS", "-N", "--connect-timeout", "5", "-H", "Content-Type: application/json",
                        "--data-binary", "@-", host + "/api/chat"]
    chatProc.stdinEnabled = true
    chatProc.running = true
    stats = "Waiting for " + appState.model + "…"
    chatList.scrollToEnd()
  }

  function onChunk(line) {
    if (!String(line).trim()) return
    var chunk = null
    try { chunk = JSON.parse(line) } catch (e) { return }
    if (chunk.error) {
      chatProc.errorText = chunk.error
      chatProc.running = false
      return
    }
    if (liveIndex < 0) return
    var reply = history[liveIndex]
    var m = chunk.message || {}
    if ((m.content || m.thinking) && chatProc.firstTokenMs < 0)
      chatProc.firstTokenMs = Date.now() - chatProc.startedAt
    if (m.thinking) {
      reply.thinking += m.thinking
      chatModel.setProperty(liveIndex, "thinking", reply.thinking)
    }
    if (m.content) {
      reply.content += m.content
      chatModel.setProperty(liveIndex, "body", reply.content)
    }
    if (chunk.done) chatProc.done = chunk
    stats = reply.content ? "Generating…" : reply.thinking ? "Thinking…" : stats
    if (opened) chatList.scrollToEnd()
  }

  function finish() {
    var index = liveIndex
    liveIndex = -1
    if (index < 0) return  // cleared mid-reply
    var reply = history[index]
    var error = ""
    if (chatProc.errorText) error = chatProc.errorText
    else if (chatProc.stopped) stats = "Stopped"
    else if (chatProc.done) stats = formatStats(chatProc.done, chatProc.firstTokenMs)
    else {
      stats = "Connection ended early"
      if (!reply.content) error = chatErr.text.trim() || "No response"
    }
    if (error) {
      reply.error = true
      reply.content = error
      chatModel.setProperty(index, "body", error)
      chatModel.setProperty(index, "error", true)
      ping()
    } else if (!reply.content) {
      chatModel.setProperty(index, "body", "(empty reply)")
    }
    if (opened) chatList.scrollToEnd()
  }

  function stop() {
    if (!chatProc.running) return
    chatProc.stopped = true
    chatProc.running = false
  }

  function clearChat() {
    liveIndex = -1
    stop()
    history = []
    chatModel.clear()
    stats = ""
    input.forceActiveFocus()
  }

  Process {
    id: chatProc
    property string body: ""
    property string model: ""
    property double startedAt: 0
    property double firstTokenMs: -1
    property var done: null
    property bool stopped: false
    property string errorText: ""
    // The request body goes over stdin: base64 images are far too big for argv.
    onStarted: {
      write(body)
      body = ""
      stdinEnabled = false
    }
    stdout: SplitParser { onRead: function(line) { root.onChunk(line) } }
    stderr: StdioCollector { id: chatErr }
    onExited: Qt.callLater(root.finish)
  }

  // ------------------------------------------------------------------ attachments, clipboard

  function addAttachmentLine(line) {
    var a = null
    try { a = JSON.parse(line) } catch (e) { return }
    if (a.kind === "error") {
      stats = "Couldn't attach " + a.name + ": " + a.error
      return
    }
    attachments = attachments.concat([a])
    stats = a.cut ? a.name + " was cut to its first 100k characters" : ""
  }

  function attachFiles(paths) {
    if (!paths.length || attachProc.running) return
    attachProc.command = [binDir + "/ollama-chat-attach"].concat(paths)
    attachProc.running = true
  }

  function removeAttachment(index) {
    var list = attachments.slice()
    list.splice(index, 1)
    attachments = list
    input.forceActiveFocus()
  }

  function pasteClipboard() {
    if (pasteProc.running) return
    pasteProc.running = true
  }

  function copyText(text) {
    copyProc.payload = text
    copyProc.stdinEnabled = true
    copyProc.running = true
    stats = "Copied to clipboard"
  }

  Process {
    id: attachProc
    stdout: SplitParser { onRead: function(line) { root.addAttachmentLine(line) } }
  }

  Process {
    id: pickProc
    command: ["omarchy-file-select", "--title", "Attach to Ollama chat", "--multiple"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.attachFiles(text.split("\n").filter(function(l) { return l.trim() !== "" }))
        if (root.opened) input.forceActiveFocus()
      }
    }
  }

  // Exit 3 = clipboard holds plain text: fall back to the field's own paste.
  Process {
    id: pasteProc
    command: [root.binDir + "/ollama-chat-paste"]
    stdout: SplitParser { onRead: function(line) { root.addAttachmentLine(line) } }
    onExited: function(code) { if (code === 3) input.paste() }
  }

  Process {
    id: copyProc
    property string payload: ""
    command: ["wl-copy"]
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
  }

  // ------------------------------------------------------------------ open / close

  function setOpen(open) {
    if (open === opened) return
    pickerOpen = false
    if (open) {
      chatWindow.placeUnderButton()
      refreshModels()
    }
    opened = open
  }

  IpcHandler {
    target: "jim.ollama-chat"
    function toggle(): void { root.setOpen(!root.opened) }
    function open(): void { root.setOpen(true) }
    function close(): void { root.setOpen(false) }
    // Scriptable: omarchy-shell jim.ollama-chat ask "why is the sky blue?"
    function ask(text: string): void {
      root.setOpen(true)
      input.text = text
      root.send()
    }
    function attach(path: string): void { root.attachFiles([path]) }
  }

  // ------------------------------------------------------------------ bar icon

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened
    tooltipText: !root.pinged ? "Ollama" : root.online ? "Ollama · " + root.hostLabel : "Ollama · unreachable"
    iconComponent: Item {
      Image {
        id: logo
        anchors.centerIn: parent
        width: Style.bar.iconCanvas
        height: width
        sourceSize: Qt.size(width * 2, height * 2)
        source: Qt.resolvedUrl("assets/ollama.svg")
        visible: false
      }
      MultiEffect {
        anchors.fill: logo
        source: logo
        colorization: 1.0
        colorizationColor: root.busy ? Color.accent : button.foreground
        opacity: root.online || !root.pinged ? 1.0 : 0.4
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.setOpen(!root.opened)
      else if (buttonCode === Qt.RightButton) root.refreshModels()
    }
  }

  // ------------------------------------------------------------------ panel

  component ChatButton: Button {
    foreground: Color.popups.text
    bordered: true
    fontSize: Style.font.body
  }

  PanelWindow {
    id: chatWindow

    readonly property var barWindow: button.QsWindow.window
    readonly property string barPos: root.bar ? root.bar.position : "top"
    property real xOffset: Style.gapsOut
    property bool focusPrimed: false

    function placeUnderButton() {
      if (!barWindow || !screen) return
      var p = button.mapToItem(null, button.width / 2, 0)
      xOffset = Math.max(Style.gapsOut, Math.min(p.x - implicitWidth / 2, screen.width - implicitWidth - Style.gapsOut))
    }

    screen: barWindow ? barWindow.screen : null
    visible: root.opened
    color: "transparent"
    implicitWidth: Style.space(470)
    implicitHeight: Style.space(600)
    exclusionMode: ExclusionMode.Normal

    anchors {
      top: barPos !== "bottom"
      bottom: barPos === "bottom"
      left: true
    }
    margins {
      top: Style.gapsOut
      bottom: Style.gapsOut
      left: xOffset
    }

    WlrLayershell.namespace: "jim-ollama-chat"
    WlrLayershell.layer: WlrLayer.Top
    // Same trick as Omarchy's KeyboardPanel: a brief Exclusive grab so the panel has
    // keyboard focus the moment it opens, then OnDemand so the rest of the desktop
    // stays usable (click a window to type there, click the panel to type here).
    WlrLayershell.keyboardFocus: root.opened
      ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    onVisibleChanged: {
      if (!visible) return
      focusPrimed = false
      primeTimer.restart()
      Qt.callLater(function() { input.forceActiveFocus() })
    }

    Timer {
      id: primeTimer
      interval: 250
      onTriggered: chatWindow.focusPrimed = true
    }

    BorderSurface {
      id: card
      anchors.fill: parent
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius

      FocusScope {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true
        Keys.onEscapePressed: root.setOpen(false)

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.spacing.lg

          // Header: status dot · title · host · close
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            Text {
              text: "●"
              color: !root.pinged ? root.dim : root.online ? Color.accent : Color.urgent
              font.pixelSize: Style.font.body
            }
            Text {
              text: "Ollama"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: !root.pinged ? root.hostLabel
                : !root.online ? root.hostLabel + " · unreachable"
                : root.serverVersion ? root.hostLabel + " · v" + root.serverVersion : root.hostLabel
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            ChatButton {
              text: "✕"
              bordered: false
              onClicked: root.setOpen(false)
            }
          }

          // Model picker · Think · Clear
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            ChatButton {
              Layout.fillWidth: true
              leftAlign: true
              text: (root.appState.model || (root.models.length ? "Choose model" : "No models")) + "  ▾"
              selected: root.pickerOpen
              onClicked: root.pickerOpen = !root.pickerOpen
            }
            ChatButton {
              visible: root.canThink
              text: "Think"
              selected: !!root.appState.think
              onClicked: root.setStateKey("think", !root.appState.think)
            }
            ChatButton {
              text: "Clear"
              onClicked: root.clearChat()
            }
          }

          // Model list
          ListView {
            id: modelList
            visible: root.pickerOpen
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, Style.space(220))
            clip: true
            model: root.models
            spacing: Style.spacing.xs
            delegate: ChatButton {
              required property var modelData
              width: modelList.width
              bordered: false
              leftAlign: true
              selected: modelData.name === root.appState.model
              text: {
                var d = modelData.details || {}
                var bits = [d.parameter_size, d.quantization_level, root.formatSize(modelData.size)]
                if (root.loadedModels.indexOf(modelData.name) >= 0) bits.unshift("loaded")
                return modelData.name + "   ·   " + bits.filter(function(b) { return !!b }).join(" · ")
              }
              onClicked: {
                root.setStateKey("model", modelData.name)
                root.pickerOpen = false
                input.forceActiveFocus()
              }
            }
          }

          // Conversation
          ListView {
            id: chatList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.spacing.lg
            model: chatModel
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            function scrollToEnd() { Qt.callLater(function() { chatList.positionViewAtEnd() }) }

            Text {
              anchors.centerIn: parent
              width: parent.width
              visible: chatModel.count === 0
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              text: "Ask something to test the model.\nClick a message to copy it."
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            delegate: Column {
              id: msg
              required property int index
              required property string role
              required property string body
              required property string thinking
              required property string files
              required property bool error
              readonly property bool mine: role === "user"
              width: chatList.width - Style.space(8)
              spacing: Style.spacing.xs

              Text {
                width: parent.width
                visible: msg.thinking !== ""
                text: msg.thinking
                wrapMode: Text.Wrap
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }

              Rectangle {
                id: bubble
                readonly property real maxWidth: parent.width * (msg.mine ? 0.85 : 1.0)
                anchors.right: msg.mine ? parent.right : undefined
                width: Math.min(maxWidth, bodyText.implicitWidth + Style.space(20))
                height: bodyText.implicitHeight + Style.space(14)
                radius: Style.cornerRadius
                color: msg.mine ? Util.alpha(Color.accent, 0.16) : Util.alpha(Color.popups.text, 0.06)
                border.width: msg.error ? Math.max(1, Style.space(1)) : 0
                border.color: Color.urgent

                Text {
                  id: bodyText
                  x: Style.space(10)
                  y: Style.space(7)
                  width: Math.min(implicitWidth, bubble.maxWidth - Style.space(20))
                  text: msg.body !== "" ? msg.body : (msg.mine ? "" : "…")
                  textFormat: msg.mine || msg.error ? Text.PlainText : Text.MarkdownText
                  wrapMode: Text.Wrap
                  color: msg.error ? Color.urgent : Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var h = root.history[msg.index]
                    root.copyText(msg.mine || !h ? msg.body : h.content)
                  }
                }
              }

              Text {
                anchors.right: msg.mine ? parent.right : undefined
                visible: msg.files !== ""
                text: "󰁦 " + msg.files
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Attachments waiting to be sent
          Flow {
            Layout.fillWidth: true
            visible: root.attachments.length > 0
            spacing: Style.spacing.md
            Repeater {
              model: root.attachments
              delegate: Rectangle {
                id: chip
                required property var modelData
                required property int index
                width: chipRow.implicitWidth + Style.space(12)
                height: chipRow.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: Util.alpha(Color.popups.text, 0.08)
                Row {
                  id: chipRow
                  anchors.centerIn: parent
                  spacing: Style.spacing.md
                  Image {
                    visible: chip.modelData.kind === "image"
                    width: Style.space(36)
                    height: Style.space(36)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: chip.modelData.kind === "image" ? "data:image;base64," + chip.modelData.b64 : ""
                  }
                  Text {
                    visible: chip.modelData.kind !== "image"
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰈙"
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: chip.modelData.name
                    elide: Text.ElideMiddle
                    width: Math.min(implicitWidth, Style.space(180))
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "×"
                    color: root.dim
                    font.pixelSize: Style.font.title
                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeAttachment(chip.index)
                    }
                  }
                }
              }
            }
          }

          // Prompt
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            ChatButton {
              text: "+"
              tooltipText: "Attach files (or paste with Ctrl+V / Super+V)"
              onClicked: if (!pickProc.running) pickProc.running = true
            }
            TextField {
              id: input
              Layout.fillWidth: true
              focus: true
              foreground: Color.popups.text
              placeholderText: "Message… (Ctrl+V pastes images and files)"
              onAccepted: root.send()
              // Ctrl+V, and Shift+Insert (what Omarchy's Super+V sends): images and copied
              // files become attachments; anything else pastes as text.
              Keys.onPressed: function(event) {
                var ctrlV = event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)
                var shiftIns = event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier)
                if (ctrlV || shiftIns) {
                  root.pasteClipboard()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.setOpen(false)
                  event.accepted = true
                }
              }
            }
            ChatButton {
              text: root.busy ? "Stop" : "Send"
              selected: root.busy
              onClicked: root.busy ? root.stop() : root.send()
            }
          }

          Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: root.stats
            wrapMode: Text.Wrap
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
