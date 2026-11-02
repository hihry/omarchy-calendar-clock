// Pure date, format, and calendar task/event color math for the clock widget
// and its calendar panel. Everything here is locale- and Qt-free so it can be
// unit tested under node.

var MS_PER_DAY = 86400000

var WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

var CLOCK_FORMATS = [
  "dddd HH:mm",
  "dddd h:mm AP",
  "HH:mm",
  "h:mm AP",
  "ddd d MMM HH:mm",
  "ddd d MMM h:mm AP",
  "d MMMM 'W'ww yyyy",
  "yyyy-MM-dd HH:mm"
]

var VERTICAL_CLOCK_FORMATS = [
  "HH\n—\nmm",
  "h\n—\nmm\nAP",
  "dd\nMMM\n'W'ww\n''yy",
  "HH\nmm"
]

var GCAL_COLOR_PRESETS = [
  { id: "7", name: "Peacock", hex: "#039be5" },
  { id: "11", name: "Tomato", hex: "#d50000" },
  { id: "2", name: "Sage", hex: "#33b679" },
  { id: "5", name: "Banana", hex: "#f6bf26" },
  { id: "3", name: "Grape", hex: "#8e24aa" },
  { id: "6", name: "Tangerine", hex: "#f4511e" },
  { id: "9", name: "Blueberry", hex: "#3f51b5" },
  { id: "1", name: "Lavender", hex: "#7986cb" }
]

var TASK_COLOR_SWATCHES = [
  { key: "", label: "Priority Auto", hex: "" },
  { key: "#e06c75", label: "Coral Red", hex: "#e06c75" },
  { key: "#039be5", label: "Ocean Blue", hex: "#039be5" },
  { key: "#33b679", label: "Emerald Sage", hex: "#33b679" },
  { key: "#f6bf26", label: "Amber Gold", hex: "#f6bf26" },
  { key: "#8e24aa", label: "Amethyst", hex: "#8e24aa" }
]

function clockFormats(vertical) {
  return vertical ? VERTICAL_CLOCK_FORMATS.slice() : CLOCK_FORMATS.slice()
}

function clockFormatRing(configured, configuredAlt, presets) {
  var ring = []
  var candidates = (presets || []).concat([configuredAlt, configured])
  for (var i = 0; i < candidates.length; i++) {
    var format = String(candidates[i] === undefined || candidates[i] === null ? "" : candidates[i])
    if (format === "" || ring.indexOf(format) !== -1) continue
    ring.push(format)
  }
  return ring.length > 0 ? ring : ["HH:mm"]
}

function nextClockFormat(ring, current) {
  if (!ring || ring.length === 0) return ""
  var index = ring.indexOf(String(current === undefined || current === null ? "" : current))
  return ring[(index + 1) % ring.length]
}

function isoWeekLiteral(year, month, day) {
  return pad2(isoWeek(year, month, day))
}

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function stepDateKey(baseDateKey, deltaDays) {
  var parts = String(baseDateKey || "").split("-")
  if (parts.length !== 3) return String(baseDateKey || "")
  var y = parseInt(parts[0], 10)
  var m = parseInt(parts[1], 10) - 1
  var d = parseInt(parts[2], 10)
  if (!isFinite(y) || !isFinite(m) || !isFinite(d)) return String(baseDateKey || "")
  var dt = new Date(Date.UTC(y, m, d + Number(deltaDays || 0)))
  return dateKey(dt.getUTCFullYear(), dt.getUTCMonth(), dt.getUTCDate())
}

function coerceWeekStart(value) {
  if (value === undefined || value === null) return null
  if (typeof value === "number")
    return isFinite(value) ? ((Math.round(value) % 7) + 7) % 7 : null

  var text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "") return null

  for (var i = 0; i < WEEKDAY_NAMES.length; i++)
    if (WEEKDAY_NAMES[i] === text || WEEKDAY_NAMES[i].substr(0, 3) === text) return i

  var parsed = parseInt(text, 10)
  return isFinite(parsed) ? ((parsed % 7) + 7) % 7 : null
}

function normalizedWeekStart(value, fallback) {
  var configured = coerceWeekStart(value)
  if (configured !== null) return configured
  var fallbackStart = coerceWeekStart(fallback)
  return fallbackStart === null ? 1 : fallbackStart
}

function weekStartSettingName(index) {
  return WEEKDAY_NAMES[normalizedWeekStart(index, 1)]
}

function toggledWeekStart(index) {
  return normalizedWeekStart(index, 1) === 1 ? 0 : 1
}

function weekdayOrder(weekStart) {
  var start = normalizedWeekStart(weekStart, 1)
  var out = []
  for (var i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

function isoWeek(year, month, day) {
  var date = new Date(Date.UTC(year, month, day))
  var weekday = date.getUTCDay() || 7
  date.setUTCDate(date.getUTCDate() + 4 - weekday)
  var yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
  return Math.ceil(((date.getTime() - yearStart.getTime()) / MS_PER_DAY + 1) / 7)
}

function dayOfYear(year, month, day) {
  return Math.round((Date.UTC(year, month, day) - Date.UTC(year, 0, 1)) / MS_PER_DAY) + 1
}

function daysInYear(year) {
  return dayOfYear(year, 11, 31)
}

function yearProgress(year, month, day) {
  var total = daysInYear(year)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (dayOfYear(year, month, day) - 1) / total))
}

function yearProgressPercent(year, month, day) {
  return Math.round(yearProgress(year, month, day) * 100)
}

var DEFAULT_LIFE_EXPECTANCY = 90

function parseBirthYear(value, currentYear) {
  var now = Math.round(Number(currentYear))
  if (!isFinite(now)) return 0
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d{4}$/.test(text)) return 0
  var year = parseInt(text, 10)
  if (!isFinite(year) || year > now || year < now - 120) return 0
  return year
}

function ageFromBirthYear(birthYear, currentYear) {
  var born = parseBirthYear(birthYear, currentYear)
  if (born <= 0) return 0
  return Math.round(Number(currentYear)) - born
}

function parseAge(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return 0
  var years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 120) return 0
  return years
}

function parseLifeExpectancy(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return DEFAULT_LIFE_EXPECTANCY
  var years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 150) return DEFAULT_LIFE_EXPECTANCY
  return years
}

function lifeProgress(age, expectancy) {
  var years = parseAge(age)
  var span = parseLifeExpectancy(expectancy)
  if (years <= 0 || span <= 0) return 0
  return Math.max(0, Math.min(1, years / span))
}

function lifeProgressPercent(age, expectancy) {
  return Math.round(lifeProgress(age, expectancy) * 100)
}

function monthGrid(year, month, weekStart, todayKey) {
  var start = normalizedWeekStart(weekStart, 1)
  var leading = (new Date(Date.UTC(year, month, 1)).getUTCDay() - start + 7) % 7
  var cursor = new Date(Date.UTC(year, month, 1 - leading))
  var today = String(todayKey || "")
  var weeks = []

  for (var w = 0; w < 6; w++) {
    var days = []
    var thursday = null
    for (var d = 0; d < 7; d++) {
      var cellYear = cursor.getUTCFullYear()
      var cellMonth = cursor.getUTCMonth()
      var cellDay = cursor.getUTCDate()
      var weekday = cursor.getUTCDay()
      var key = dateKey(cellYear, cellMonth, cellDay)
      if (weekday === 4) thursday = { year: cellYear, month: cellMonth, day: cellDay }
      days.push({
        key: key,
        year: cellYear,
        month: cellMonth,
        day: cellDay,
        weekday: weekday,
        inMonth: cellMonth === month && cellYear === year,
        weekend: weekday === 0 || weekday === 6,
        today: key === today
      })
      cursor.setUTCDate(cursor.getUTCDate() + 1)
    }
    var anchor = thursday || days[0]
    weeks.push({
      week: isoWeek(anchor.year, anchor.month, anchor.day),
      days: days
    })
  }
  return weeks
}

function stepMonth(year, month, delta) {
  var target = new Date(Date.UTC(year, Number(month) + Number(delta), 1))
  return { year: target.getUTCFullYear(), month: target.getUTCMonth() }
}

// ---- Task & Google Calendar Event Color Helpers ----------------------------

function priorityRank(priority) {
  if (priority === "high") return 0
  if (priority === "normal") return 1
  return 2
}

function isValidHexColor(value) {
  return typeof value === "string" && /^#[0-9A-Fa-f]{6}$/.test(value.replace(/^\s+|\s+$/g, ""))
}

function taskColorFor(task, fallbackColors) {
  var defaults = fallbackColors || {}
  var highColor = defaults.high || "#e06c75"
  var normalColor = defaults.normal || "#039be5"
  var lowColor = defaults.low || "#33b679"
  var doneColor = defaults.done || "#56b6c2"

  if (!task) return normalColor
  var custom = isValidHexColor(task.color) ? task.color.replace(/^\s+|\s+$/g, "") : ""
  if (task.done) return custom || doneColor
  if (custom) return custom
  if (task.priority === "high") return highColor
  if (task.priority === "low") return lowColor
  return normalColor
}

function parseDailyTasksState(rawText, todayKey) {
  var byDate = {}
  var text = String(rawText || "").replace(/^\s+|\s+$/g, "")
  var today = String(todayKey || "")
  var tomorrow = today ? stepDateKey(today, 1) : ""
  if (!text) return { tasksByDate: byDate, count: 0 }

  try {
    var parsed = JSON.parse(text)
    var list = parsed && Array.isArray(parsed.tasks) ? parsed.tasks : []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (!item || typeof item !== "object") continue
      var title = String(item.text || "").replace(/^\s+|\s+$/g, "")
      if (!title) continue
      var isDone = item.done === true
      var dKey = typeof item.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(item.date)
        ? item.date
        : (item.day === "tomorrow" ? tomorrow : today)
      if (!dKey) continue
      if (today && dKey < today && !isDone) dKey = today

      if (!byDate[dKey]) byDate[dKey] = []
      byDate[dKey].push({
        id: String(item.id || ""),
        text: title,
        date: dKey,
        day: String(item.day || "today"),
        priority: item.priority === "high" || item.priority === "low" ? item.priority : "normal",
        color: isValidHexColor(item.color) ? item.color.replace(/^\s+|\s+$/g, "") : "",
        done: isDone,
        carriedOver: item.carriedOver === true,
        createdAt: Number(item.createdAt) || 0
      })
    }
  } catch (e) {
    return { tasksByDate: {}, count: 0 }
  }

  var total = 0
  for (var k in byDate) {
    byDate[k].sort(function(a, b) {
      if (!!a.done !== !!b.done) return a.done ? 1 : -1
      var pa = priorityRank(a.priority)
      var pb = priorityRank(b.priority)
      if (pa !== pb) return pa - pb
      return a.createdAt - b.createdAt
    })
    total += byDate[k].length
  }
  return { tasksByDate: byDate, count: total }
}

function parseGcalEventsState(rawText) {
  var empty = {
    hasCredentials: false,
    credentialsPath: "",
    authenticated: false,
    syncedAt: 0,
    lastError: "",
    palette: {},
    eventsByDate: {}
  }
  var text = String(rawText || "").replace(/^\s+|\s+$/g, "")
  if (!text) return empty
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return empty
    return {
      hasCredentials: parsed.hasCredentials === true,
      credentialsPath: String(parsed.credentialsPath || ""),
      authenticated: parsed.authenticated === true,
      syncedAt: Number(parsed.syncedAt) || 0,
      lastError: String(parsed.lastError || ""),
      palette: parsed.palette && typeof parsed.palette === "object" ? parsed.palette : {},
      eventsByDate: parsed.eventsByDate && typeof parsed.eventsByDate === "object" ? parsed.eventsByDate : {}
    }
  } catch (e) {
    return empty
  }
}

function daySummaryFor(dKey, tasksByDate, eventsByDate, fallbackColors) {
  var tasks = (tasksByDate && Array.isArray(tasksByDate[dKey])) ? tasksByDate[dKey] : []
  var events = (eventsByDate && Array.isArray(eventsByDate[dKey])) ? eventsByDate[dKey] : []

  var pendingTasks = 0
  var completedTasks = 0
  var highPriorityPending = 0

  var highDotItems = []
  var normalTaskDots = []
  var doneTaskDots = []
  var eventDots = []

  for (var i = 0; i < tasks.length; i++) {
    var t = tasks[i]
    var tColor = taskColorFor(t, fallbackColors)
    if (t.done) {
      completedTasks++
      doneTaskDots.push({ color: tColor, kind: "task", done: true, title: t.text })
    } else {
      pendingTasks++
      if (t.priority === "high") {
        highPriorityPending++
        highDotItems.push({ color: tColor, kind: "task", done: false, title: t.text })
      } else {
        normalTaskDots.push({ color: tColor, kind: "task", done: false, title: t.text })
      }
    }
  }

  for (var j = 0; j < events.length; j++) {
    var ev = events[j]
    var evColor = isValidHexColor(ev.color) ? ev.color : "#039be5"
    eventDots.push({
      color: evColor,
      kind: "event",
      done: ev.done === true,
      title: String(ev.title || "Event")
    })
  }

  var orderedDots = highDotItems.concat(eventDots, normalTaskDots, doneTaskDots)
  var visibleDots = orderedDots.slice(0, 4)
  var totalCount = orderedDots.length
  var overflowCount = Math.max(0, totalCount - 4)

  var dominantColor = orderedDots.length > 0 ? orderedDots[0].color : ""
  var tintAlpha = 0
  if (highPriorityPending > 0) tintAlpha = 0.22
  else if (pendingTasks > 0 || events.length > 0) tintAlpha = 0.15
  else if (completedTasks > 0) tintAlpha = 0.08

  var tooltipParts = []
  if (events.length > 0) {
    tooltipParts.push(events.length + (events.length === 1 ? " event" : " events"))
  }
  if (pendingTasks > 0) {
    var pLabel = pendingTasks + (pendingTasks === 1 ? " pending task" : " pending tasks")
    if (highPriorityPending > 0) pLabel += " (" + highPriorityPending + " high)"
    tooltipParts.push(pLabel)
  }
  if (completedTasks > 0) {
    tooltipParts.push(completedTasks + " done")
  }

  return {
    tasks: tasks,
    events: events,
    pendingTasks: pendingTasks,
    completedTasks: completedTasks,
    highPriorityPending: highPriorityPending,
    eventCount: events.length,
    totalCount: totalCount,
    dots: visibleDots,
    overflowCount: overflowCount,
    dominantColor: dominantColor,
    tintAlpha: tintAlpha,
    tooltip: tooltipParts.join(" · ")
  }
}

function monthGridWithSummaries(year, month, weekStart, todayKey, tasksByDate, eventsByDate, fallbackColors) {
  var baseWeeks = monthGrid(year, month, weekStart, todayKey)
  for (var w = 0; w < baseWeeks.length; w++) {
    var days = baseWeeks[w].days
    for (var d = 0; d < days.length; d++) {
      var cell = days[d]
      cell.summary = daySummaryFor(cell.key, tasksByDate, eventsByDate, fallbackColors)
    }
  }
  return baseWeeks
}

if (typeof module !== "undefined") {
  module.exports = {
    GCAL_COLOR_PRESETS: GCAL_COLOR_PRESETS,
    TASK_COLOR_SWATCHES: TASK_COLOR_SWATCHES,
    dateKey: dateKey,
    keyForDate: keyForDate,
    stepDateKey: stepDateKey,
    normalizedWeekStart: normalizedWeekStart,
    weekStartSettingName: weekStartSettingName,
    toggledWeekStart: toggledWeekStart,
    weekdayOrder: weekdayOrder,
    isoWeek: isoWeek,
    dayOfYear: dayOfYear,
    daysInYear: daysInYear,
    yearProgress: yearProgress,
    yearProgressPercent: yearProgressPercent,
    parseAge: parseAge,
    parseBirthYear: parseBirthYear,
    ageFromBirthYear: ageFromBirthYear,
    parseLifeExpectancy: parseLifeExpectancy,
    lifeProgress: lifeProgress,
    lifeProgressPercent: lifeProgressPercent,
    monthGrid: monthGrid,
    monthGridWithSummaries: monthGridWithSummaries,
    stepMonth: stepMonth,
    clockFormats: clockFormats,
    clockFormatRing: clockFormatRing,
    nextClockFormat: nextClockFormat,
    isoWeekLiteral: isoWeekLiteral,
    taskColorFor: taskColorFor,
    parseDailyTasksState: parseDailyTasksState,
    parseGcalEventsState: parseGcalEventsState,
    daySummaryFor: daySummaryFor
  }
}
