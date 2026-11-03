import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Enhanced Omarchy Clock calendar popup with:
// - Task & Google Calendar event color tints and multi-color dots on date cells
// - Interactive date selection & Day Agenda drawer
// - Quick-add for local tasks (with priority & custom color) and Google Calendar events
Panel {
  id: root
  moduleName: "omarchy.clock"
  ipcTarget: "omarchy.clock"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy"
  readonly property string tasksStatePath: stateDir + "/daily-tasks.json"
  readonly property string gcalStatePath: stateDir + "/gcal-events.json"
  readonly property string gcalScriptPath: Qt.resolvedUrl("scripts/gcal_sync.py").toString().replace(/^file:\/\//, "")
  readonly property string gcalReadmePath: (Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")) + "/omarchy/google-calendar/README.md"

  // ---- Today & Selected Date -----------------------------------------------
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  property string selectedDateKey: todayKey

  readonly property date viewDate: new Date(viewYear, viewMonth, 1, 12)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // ---- Theme Colors --------------------------------------------------------
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accentColor: Commons.Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  readonly property color mutedColor: Qt.darker(contentForeground, 1.55)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var fallbackTaskColors: ({
    high: "#e06c75",
    normal: "#039be5",
    low: "#33b679",
    done: "#56b6c2"
  })

  // ---- Tasks & Google Calendar State ---------------------------------------
  property string rawTasksJson: ""
  property string rawGcalJson: ""

  readonly property var parsedTasks: Model.parseDailyTasksState(rawTasksJson, todayKey)
  readonly property var tasksByDate: parsedTasks.tasksByDate
  readonly property var parsedGcal: Model.parseGcalEventsState(rawGcalJson)
  readonly property var eventsByDate: parsedGcal.eventsByDate
  readonly property bool gcalAuthenticated: parsedGcal.authenticated === true
  readonly property bool gcalHasCredentials: parsedGcal.hasCredentials === true
  readonly property string gcalLastError: parsedGcal.lastError || ""

  property bool gcalSyncing: gcalSyncProcess.running || gcalActionProcess.running
  property string actionMessage: ""

  // Quick-add state
  property string quickAddMode: "task"        // "task" | "gcal"
  property string quickTaskPriority: "normal" // "high" | "normal" | "low"
  property string quickTaskColor: ""          // "" (auto by priority) or hex
  property string quickGcalColorId: "7"       // Google Calendar colorId 1-11

  // ---- Grid & Week Math ----------------------------------------------------
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGridWithSummaries(
    viewYear,
    viewMonth,
    weekStart,
    todayKey,
    tasksByDate,
    eventsByDate,
    fallbackTaskColors
  )

  readonly property var selectedDaySummary: Model.daySummaryFor(
    selectedDateKey || todayKey,
    tasksByDate,
    eventsByDate,
    fallbackTaskColors
  )
  readonly property var selectedDayEvents: selectedDaySummary.events || []
  readonly property var selectedDayTasks: selectedDaySummary.tasks || []

  readonly property string selectedDateHeading: {
    var key = selectedDateKey || todayKey
    var parts = key.split("-")
    if (parts.length !== 3) return key
    var dt = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10), 12)
    var formatted = Qt.formatDate(dt, "ddd, MMM d").toUpperCase()
    if (key === todayKey) return formatted + " · TODAY"
    if (key === Model.stepDateKey(todayKey, 1)) return formatted + " · TOMORROW"
    return formatted
  }

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(38)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  // ---- Actions & Helpers ---------------------------------------------------
  function open() {
    refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLife) root.cancelEditingLife()
    if (quickAddInput && quickAddInput.activeFocus) {
      if (keyCatcher) keyCatcher.forceActiveFocus()
    }
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
    tasksFile.reload()
    gcalFile.reload()
    if (root.gcalHasCredentials && root.gcalAuthenticated) {
      root.syncGoogleCalendar()
    }
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.selectedDateKey = Model.keyForDate(today)
  }

  function selectDateCell(cellData) {
    if (!cellData) return
    root.selectedDateKey = cellData.key
    if (!cellData.inMonth) {
      root.viewYear = cellData.year
      root.viewMonth = cellData.month
    }
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    if (root.gcalHasCredentials && root.gcalAuthenticated) {
      root.syncGoogleCalendar()
    }
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  function syncGoogleCalendar() {
    if (gcalSyncProcess.running) return
    gcalSyncProcess.command = [
      "python3",
      root.gcalScriptPath,
      "sync",
      "--year", String(root.viewYear),
      "--month", String(root.viewMonth + 1)
    ]
    gcalSyncProcess.running = true
  }

  function connectGoogleCalendar() {
    if (gcalActionProcess.running) return
    if (!root.gcalHasCredentials) {
      root.showActionMessage("Place credentials.json in ~/.config/omarchy/google-calendar/ (opening setup guide…)")
      Quickshell.execDetached(["python3", root.gcalScriptPath, "auth"])
      return
    }
    root.showActionMessage("Opening browser for Google Calendar sign-in…")
    gcalActionProcess.command = ["python3", root.gcalScriptPath, "auth"]
    gcalActionProcess.running = true
  }

  function showActionMessage(msg) {
    root.actionMessage = String(msg || "")
    if (root.actionMessage !== "") actionMessageTimer.restart()
  }

  function runTaskHelper(args) {
    if (taskMutationProcess.running) {
      Quickshell.execDetached(["python3", root.gcalScriptPath].concat(args))
      return
    }
    taskMutationProcess.command = ["python3", root.gcalScriptPath].concat(args)
    taskMutationProcess.running = true
  }

  function submitQuickAdd() {
    var text = String(quickAddInput.text || "").trim()
    if (text === "") return
    var targetDate = root.selectedDateKey || root.todayKey

    if (root.quickAddMode === "gcal") {
      if (!root.gcalAuthenticated) {
        root.connectGoogleCalendar()
        return
      }
      quickAddInput.text = ""
      root.showActionMessage("Adding event to Google Calendar…")
      gcalActionProcess.command = [
        "python3",
        root.gcalScriptPath,
        "add-event",
        "--date", targetDate,
        "--title", text,
        "--color-id", root.quickGcalColorId
      ]
      gcalActionProcess.running = true
    } else {
      quickAddInput.text = ""
      root.runTaskHelper([
        "add-task",
        "--date", targetDate,
        "--text", text,
        "--priority", root.quickTaskPriority,
        "--color", root.quickTaskColor
      ])
    }
  }

  function toggleTaskFromCalendar(taskId) {
    if (!taskId) return
    root.runTaskHelper(["toggle-task", "--id", String(taskId)])
  }

  function cycleTaskPriorityFromCalendar(taskId) {
    if (!taskId) return
    root.runTaskHelper(["cycle-priority", "--id", String(taskId)])
  }

  function deleteTaskFromCalendar(taskId) {
    if (!taskId) return
    root.runTaskHelper(["delete-task", "--id", String(taskId)])
  }

  function priorityShortBadge(priority) {
    if (priority === "high") return "! HIGH"
    if (priority === "low") return "↓ LOW"
    return "• NORM"
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  function colorWithAlpha(hexOrColor, alphaVal) {
    var c = Qt.color(hexOrColor)
    return Qt.rgba(c.r, c.g, c.b, alphaVal)
  }

  // ---- Watchers, Processes & Timers ----------------------------------------
  FileView {
    id: tasksFile
    path: root.tasksStatePath
    watchChanges: true
    printErrors: false
    onLoaded: root.rawTasksJson = text()
    onFileChanged: reload()
    onLoadFailed: root.rawTasksJson = ""
  }

  FileView {
    id: gcalFile
    path: root.gcalStatePath
    watchChanges: true
    printErrors: false
    onLoaded: root.rawGcalJson = text()
    onFileChanged: reload()
    onLoadFailed: root.rawGcalJson = ""
  }

  Process {
    id: taskMutationProcess
    running: false
    command: []
    onExited: function(exitCode) {
      tasksFile.reload()
    }
  }

  Process {
    id: gcalSyncProcess
    running: false
    command: []
    onExited: function(exitCode) {
      gcalFile.reload()
    }
  }

  Process {
    id: gcalActionProcess
    running: false
    command: []
    stdout: StdioCollector { id: gcalActionOut }
    onExited: function(exitCode) {
      gcalFile.reload()
      if (exitCode === 0) {
        root.showActionMessage("Google Calendar synced!")
      } else {
        try {
          var parsed = JSON.parse(gcalActionOut.text || "{}")
          root.showActionMessage(parsed.error || "Google Calendar action failed")
        } catch (e) {
          root.showActionMessage("Google Calendar action failed")
        }
      }
    }
  }

  Timer {
    id: gcalPeriodicTimer
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.gcalHasCredentials && root.gcalAuthenticated) {
        root.syncGoogleCalendar()
      } else {
        gcalSyncProcess.command = ["python3", root.gcalScriptPath, "status"]
        gcalSyncProcess.running = true
      }
    }
  }

  Timer {
    id: actionMessageTimer
    interval: 4500
    repeat: false
    onTriggered: root.actionMessage = ""
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      var wasTodaySelected = root.selectedDateKey === root.todayKey
      root.today = clock.date
      if (wasTodaySelected) root.selectedDateKey = Model.keyForDate(clock.date)
      if (followToday) root.goToToday()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || quickAddInput.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered ---------------------------------------
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Commons.Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 44
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Commons.Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 48
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth || root.selectedDateKey !== root.todayKey
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress -----------------------------------------------
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(4)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Commons.Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori ------------------------------------------------
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Commons.Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Color-Coded Month Grid --------------------------------------
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              y: Style.space(12)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Commons.Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Commons.Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      id: dayCell
                      required property var modelData

                      readonly property bool isSelected: modelData.key === root.selectedDateKey
                      readonly property var summary: modelData.summary || ({ dots: [], dominantColor: "", tintAlpha: 0, tooltip: "", overflowCount: 0, highPriorityPending: 0 })
                      readonly property bool hasDots: summary.dots && summary.dots.length > 0

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)

                      color: {
                        if (cellMouse.containsMouse) {
                          return Style.hoverFillFor(root.contentForeground, Commons.Color.accent)
                        }
                        if (summary.dominantColor !== "" && summary.tintAlpha > 0) {
                          var alpha = modelData.inMonth ? summary.tintAlpha : (summary.tintAlpha * 0.45)
                          return root.colorWithAlpha(summary.dominantColor, alpha)
                        }
                        if (isSelected) {
                          return Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.12)
                        }
                        return "transparent"
                      }

                      border.width: {
                        if (modelData.today) return Math.max(2, Style.spacing.hairline * 2)
                        if (isSelected) return Math.max(1, Style.spacing.hairline)
                        if (summary.highPriorityPending > 0 && modelData.inMonth) return 1
                        return 0
                      }

                      border.color: {
                        if (modelData.today) return Style.normalBorderFor(root.contentForeground, Commons.Color.accent)
                        if (isSelected) return Commons.Color.accent
                        if (summary.dominantColor !== "") return root.colorWithAlpha(summary.dominantColor, 0.55)
                        return "transparent"
                      }

                      Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: dayCell.hasDots ? -Style.space(4) : 0
                        text: dayCell.modelData.day
                        color: dayCell.modelData.inMonth
                          ? (dayCell.modelData.weekend ? Qt.darker(root.contentForeground, 1.35) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: dayCell.modelData.today || dayCell.isSelected
                      }

                      // Colored task & Google Calendar event indicator dots
                      Row {
                        visible: dayCell.hasDots
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(4)
                        spacing: Style.space(3)

                        Repeater {
                          model: dayCell.summary.dots

                          Rectangle {
                            required property var modelData
                            width: Style.space(5)
                            height: Style.space(5)
                            radius: width / 2
                            color: modelData.color
                            opacity: !dayCell.modelData.inMonth
                              ? 0.45
                              : (modelData.done ? 0.55 : 1.0)
                          }
                        }

                        Text {
                          visible: dayCell.summary.overflowCount > 0
                          textFormat: Text.PlainText
                          text: "+"
                          color: dayCell.summary.dominantColor !== ""
                            ? dayCell.summary.dominantColor
                            : root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.space(8)
                          font.bold: true
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      MouseArea {
                        id: cellMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectDateCell(dayCell.modelData)
                      }

                      PanelToolTip {
                        visible: cellMouse.containsMouse && dayCell.summary.tooltip !== ""
                        text: dayCell.summary.tooltip
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }
                }
              }
            }

            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month Stepping ----------------------------------------------
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(8)

              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(150)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- Selected Date Agenda & Quick-Add Drawer ---------------------
          Item {
            width: parent.width
            height: agendaBox.implicitHeight + Style.space(6)

            Column {
              id: agendaBox
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              spacing: Style.space(8)

              PanelSeparator {
                foreground: root.contentForeground
              }

              // Agenda Header + Google Calendar Sync / Connect Button
              Item {
                width: parent.width
                implicitHeight: Math.max(agendaHeaderLeft.implicitHeight, agendaHeaderRight.implicitHeight)

                Row {
                  id: agendaHeaderLeft
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: root.selectedDateHeading
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 0.8
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Rectangle {
                    visible: root.selectedDaySummary.totalCount > 0
                    width: countBadgeText.implicitWidth + Style.space(10)
                    height: countBadgeText.implicitHeight + Style.space(4)
                    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                    color: root.selectedDaySummary.dominantColor !== ""
                      ? root.colorWithAlpha(root.selectedDaySummary.dominantColor, 0.18)
                      : Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.14)
                    border.width: 1
                    border.color: root.selectedDaySummary.dominantColor !== ""
                      ? root.colorWithAlpha(root.selectedDaySummary.dominantColor, 0.45)
                      : Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: countBadgeText
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: {
                        var parts = []
                        if (root.selectedDaySummary.eventCount > 0) parts.push(root.selectedDaySummary.eventCount + " GCal")
                        if (root.selectedDaySummary.pendingTasks > 0) parts.push(root.selectedDaySummary.pendingTasks + " pending")
                        if (root.selectedDaySummary.completedTasks > 0) parts.push(root.selectedDaySummary.completedTasks + " done")
                        return parts.join(" · ")
                      }
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Row {
                  id: agendaHeaderRight
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Button {
                    text: root.gcalSyncing
                      ? "Syncing…"
                      : (root.gcalAuthenticated ? "Sync GCal" : "Connect GCal")
                    iconText: root.gcalAuthenticated ? "󰑐" : "󰊭"
                    bordered: true
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(2)
                    foreground: root.contentForeground
                    accent: root.accentColor
                    fontFamily: root.contentFontFamily
                    tooltipText: root.gcalAuthenticated
                      ? "Sync Google Calendar & Google Tasks now"
                      : (root.gcalHasCredentials
                        ? "Click to authorize Google Calendar in browser"
                        : "Setup Google Calendar OAuth2 credentials (~/.config/omarchy/google-calendar/credentials.json)")
                    onClicked: {
                      if (root.gcalAuthenticated) root.syncGoogleCalendar()
                      else root.connectGoogleCalendar()
                    }
                  }
                }
              }

              // Status / Error Banner (if any)
              Rectangle {
                visible: root.actionMessage !== ""
                width: parent.width
                height: visible ? statusBannerText.implicitHeight + Style.space(10) : 0
                radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.12)
                border.width: 1
                border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)

                Text {
                  id: statusBannerText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.margins: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: root.actionMessage
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // Empty Day Hint
              Text {
                visible: root.selectedDayEvents.length === 0 && root.selectedDayTasks.length === 0
                width: parent.width
                textFormat: Text.PlainText
                text: "No tasks or Google Calendar events on this date — add one below."
                color: Qt.darker(root.contentForeground, 1.65)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              // Combined Scrollable Agenda (Google Calendar Events + Local Tasks)
              Flickable {
                id: agendaFlick
                visible: root.selectedDayEvents.length > 0 || root.selectedDayTasks.length > 0
                width: parent.width
                height: Math.min(agendaListCol.implicitHeight, Style.space(150))
                contentWidth: width
                contentHeight: agendaListCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                QQC.ScrollBar.vertical: QQC.ScrollBar {
                  policy: QQC.ScrollBar.AsNeeded
                }

                Column {
                  id: agendaListCol
                  width: agendaFlick.width
                  spacing: Style.space(4)

                  // 1. Google Calendar / Google Tasks Events
                  Repeater {
                    model: root.selectedDayEvents

                    Rectangle {
                      id: gcalRow
                      required property var modelData

                      readonly property string evColor: Model.isValidHexColor(modelData.color) ? modelData.color : "#039be5"

                      width: agendaListCol.width
                      height: Math.max(Style.space(28), gcalTextRow.implicitHeight + Style.space(8))
                      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                      color: gcalRowMouse.containsMouse
                        ? root.colorWithAlpha(evColor, 0.18)
                        : root.colorWithAlpha(evColor, 0.10)
                      border.width: 1
                      border.color: root.colorWithAlpha(evColor, 0.35)

                      // Left color bar
                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Style.space(4)
                        radius: parent.radius
                        color: gcalRow.evColor
                      }

                      Row {
                        id: gcalTextRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Text {
                          textFormat: Text.PlainText
                          text: gcalRow.modelData.allDay
                            ? "ALL DAY"
                            : (gcalRow.modelData.startTime + (gcalRow.modelData.endTime ? "–" + gcalRow.modelData.endTime : ""))
                          color: gcalRow.evColor
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: gcalRow.modelData.title
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          font.strikeout: gcalRow.modelData.done === true
                          elide: Text.ElideRight
                          width: Math.max(Style.space(100), parent.width - Style.space(130))
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: gcalRow.modelData.calendarName || "GCal"
                          color: Qt.darker(root.contentForeground, 1.6)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      MouseArea {
                        id: gcalRowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: gcalRow.modelData.htmlLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                          if (gcalRow.modelData.htmlLink) {
                            Qt.openUrlExternally(gcalRow.modelData.htmlLink)
                          }
                        }
                      }
                    }
                  }

                  // 2. Local Daily Tasks (hihry.tasks)
                  Repeater {
                    model: root.selectedDayTasks

                    Rectangle {
                      id: calTaskRow
                      required property var modelData

                      readonly property bool isDone: modelData.done === true
                      readonly property string tColor: Model.taskColorFor(modelData, root.fallbackTaskColors)

                      width: agendaListCol.width
                      height: Math.max(Style.space(28), calTaskContent.implicitHeight + Style.space(8))
                      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                      color: isDone
                        ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.03)
                        : root.colorWithAlpha(tColor, 0.10)
                      border.width: 1
                      border.color: isDone
                        ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.10)
                        : root.colorWithAlpha(tColor, 0.35)

                      // Left color bar
                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Style.space(4)
                        radius: parent.radius
                        color: calTaskRow.tColor
                        opacity: calTaskRow.isDone ? 0.5 : 1.0
                      }

                      Item {
                        id: calTaskContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        implicitHeight: Math.max(calTaskTitle.implicitHeight, Style.space(20))

                        // Checkbox
                        Rectangle {
                          id: calCheck
                          anchors.left: parent.left
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(15)
                          height: Style.space(15)
                          radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                          color: calTaskRow.isDone ? root.colorWithAlpha(calTaskRow.tColor, 0.25) : "transparent"
                          border.width: 1.5
                          border.color: calTaskRow.tColor

                          Text {
                            anchors.centerIn: parent
                            visible: calTaskRow.isDone
                            textFormat: Text.PlainText
                            text: "✓"
                            color: calTaskRow.tColor
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.space(10)
                            font.bold: true
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleTaskFromCalendar(calTaskRow.modelData.id)
                          }
                        }

                        // Priority pill (click to cycle priority)
                        Rectangle {
                          id: calPriPill
                          anchors.left: calCheck.right
                          anchors.leftMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          width: calPriText.implicitWidth + Style.space(8)
                          height: calPriText.implicitHeight + Style.space(2)
                          radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                          color: root.colorWithAlpha(calTaskRow.tColor, 0.18)
                          opacity: calTaskRow.isDone ? 0.5 : 1.0

                          Text {
                            id: calPriText
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: root.priorityShortBadge(calTaskRow.modelData.priority)
                            color: calTaskRow.tColor
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.cycleTaskPriorityFromCalendar(calTaskRow.modelData.id)
                          }
                        }

                        // Task Title
                        Text {
                          id: calTaskTitle
                          anchors.left: calPriPill.right
                          anchors.right: calDelBtn.left
                          anchors.leftMargin: Style.space(8)
                          anchors.rightMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.PlainText
                          text: calTaskRow.modelData.text
                          elide: Text.ElideRight
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          font.strikeout: calTaskRow.isDone
                          color: calTaskRow.isDone ? Qt.darker(root.contentForeground, 1.6) : root.contentForeground

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleTaskFromCalendar(calTaskRow.modelData.id)
                          }
                        }

                        PanelActionButton {
                          id: calDelBtn
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          iconText: "󰅖"
                          foreground: Qt.darker(root.contentForeground, 1.5)
                          hoverColor: root.urgentColor
                          fontFamily: root.contentFontFamily
                          tooltipText: "Delete task"
                          onClicked: root.deleteTaskFromCalendar(calTaskRow.modelData.id)
                        }
                      }
                    }
                  }
                }
              }

              // ---- Quick-Add Input + Color & Priority Selector -------------
              Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                  id: quickAddRow
                  width: parent.width
                  spacing: Style.space(6)

                  Button {
                    id: modeToggleBtn
                    text: root.quickAddMode === "gcal" ? "GCal" : "Task"
                    iconText: root.quickAddMode === "gcal" ? "󰃭" : "󰅇"
                    bordered: true
                    selected: true
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(4)
                    foreground: root.contentForeground
                    accent: root.quickAddMode === "gcal" ? "#039be5" : root.accentColor
                    fontFamily: root.contentFontFamily
                    tooltipText: "Click to switch between adding a Daily Task vs a Google Calendar Event"
                    onClicked: {
                      root.quickAddMode = root.quickAddMode === "task" ? "gcal" : "task"
                      Qt.callLater(function() { quickAddInput.forceActiveFocus() })
                    }
                  }

                  TextField {
                    id: quickAddInput
                    width: parent.width - modeToggleBtn.implicitWidth - quickAddSubmitBtn.implicitWidth - quickAddRow.spacing * 2
                    placeholderText: root.quickAddMode === "gcal"
                      ? "(10:30-14:00) Event title, or Title (all-day)…"
                      : "Add task for " + root.selectedDateKey + "… (Enter)"
                    foreground: root.contentForeground
                    accent: root.accentColor
                    font.family: root.contentFontFamily

                    onAccepted: root.submitQuickAdd()
                    Keys.onEscapePressed: function(event) {
                      quickAddInput.focus = false
                      if (keyCatcher) keyCatcher.forceActiveFocus()
                      event.accepted = true
                    }
                  }

                  Button {
                    id: quickAddSubmitBtn
                    text: "Add"
                    iconText: "+"
                    bordered: true
                    selected: quickAddInput.text.trim() !== ""
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(4)
                    foreground: root.contentForeground
                    accent: root.accentColor
                    fontFamily: root.contentFontFamily
                    onClicked: root.submitQuickAdd()
                  }
                }

                // Priority & Color Swatches Row
                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  // Task Priority Selector (visible in "task" mode)
                  Row {
                    visible: root.quickAddMode === "task"
                    spacing: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                      model: [
                        { key: "high", label: "! High", color: "#e06c75" },
                        { key: "normal", label: "• Norm", color: "#039be5" },
                        { key: "low", label: "↓ Low", color: "#33b679" }
                      ]

                      Button {
                        required property var modelData
                        text: modelData.label
                        selected: root.quickTaskPriority === modelData.key
                        bordered: true
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(2)
                        foreground: root.contentForeground
                        accent: modelData.color
                        fontFamily: root.contentFontFamily
                        onClicked: {
                          root.quickTaskPriority = modelData.key
                          Qt.callLater(function() { quickAddInput.forceActiveFocus() })
                        }
                      }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Color:"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Task Custom Color Dots (visible in "task" mode)
                  Row {
                    visible: root.quickAddMode === "task"
                    spacing: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                      model: Model.TASK_COLOR_SWATCHES

                      Rectangle {
                        id: taskSwatch
                        required property var modelData
                        readonly property bool isChosen: root.quickTaskColor === modelData.key
                        readonly property string displayHex: modelData.hex !== ""
                          ? modelData.hex
                          : (root.quickTaskPriority === "high"
                            ? "#e06c75"
                            : (root.quickTaskPriority === "low" ? "#33b679" : "#039be5"))

                        width: Style.space(14)
                        height: Style.space(14)
                        radius: width / 2
                        color: displayHex
                        border.width: isChosen ? 2 : 0
                        border.color: root.contentForeground
                        opacity: isChosen ? 1.0 : 0.65

                        Text {
                          visible: taskSwatch.modelData.key === ""
                          anchors.centerIn: parent
                          text: "A"
                          color: "#101315"
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.space(8)
                          font.bold: true
                        }

                        MouseArea {
                          id: taskSwatchMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.quickTaskColor = taskSwatch.modelData.key
                        }

                        PanelToolTip {
                          visible: taskSwatchMouse.containsMouse
                          text: taskSwatch.modelData.label
                          fontFamily: root.contentFontFamily
                        }
                      }
                    }
                  }

                  // Google Calendar Event Color Dots (visible in "gcal" mode)
                  Row {
                    visible: root.quickAddMode === "gcal"
                    spacing: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                      model: Model.GCAL_COLOR_PRESETS

                      Rectangle {
                        id: gcalSwatch
                        required property var modelData
                        readonly property bool isChosen: root.quickGcalColorId === modelData.id

                        width: Style.space(14)
                        height: Style.space(14)
                        radius: width / 2
                        color: modelData.hex
                        border.width: isChosen ? 2 : 0
                        border.color: root.contentForeground
                        opacity: isChosen ? 1.0 : 0.65

                        MouseArea {
                          id: gcalSwatchMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.quickGcalColorId = gcalSwatch.modelData.id
                        }

                        PanelToolTip {
                          visible: gcalSwatchMouse.containsMouse
                          text: gcalSwatch.modelData.name
                          fontFamily: root.contentFontFamily
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
