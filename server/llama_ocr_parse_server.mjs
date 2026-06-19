import http from "node:http";
import { existsSync, readFileSync } from "node:fs";

loadEnvFile();

const port = Number(process.env.OCR_PARSE_PORT || 8788);
const host = process.env.HOST || "127.0.0.1";
const model = process.env.OLLAMA_MODEL || "llama3.2:1b";
const ollamaBaseUrl = process.env.OLLAMA_BASE_URL || "http://127.0.0.1:11434";
const requestTimeoutMs = Number(process.env.OLLAMA_TIMEOUT_MS || 60000);
const ollamaCleanupEnabled =
  String(process.env.OLLAMA_CLEANUP_ENABLED || "false").toLowerCase() === "true";

const server = http.createServer(async (request, response) => {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  response.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (request.method === "OPTIONS") {
    response.writeHead(204);
    response.end();
    return;
  }

  if (request.method !== "POST" || request.url !== "/parse-ocr") {
    writeJson(response, 404, { error: "Not found" });
    return;
  }

  try {
    const body = await readJson(request);
    const rawText = typeof body.rawText === "string" ? body.rawText : "";
    const lines = Array.isArray(body.lines) ? body.lines : [];
    const events = Array.isArray(body.events) ? body.events : [];
    const currentDate =
      typeof body.currentDate === "string" ? body.currentDate : "";

    if (!rawText.trim() && lines.length === 0 && events.length === 0) {
      writeJson(response, 400, { error: "rawText, lines, or events are required" });
      return;
    }

    console.log(
      `OCR parse request received: ${events.length} event block(s), ${lines.length} line(s), model=${model}, ollamaCleanup=${ollamaCleanupEnabled}`,
    );
    const result = await parseOcrLines({ rawText, lines, events, currentDate });
    console.log(`OCR parse completed: ${result.meetings.length} meeting(s)`);
    writeJson(response, 200, result);
  } catch (error) {
    console.error("OCR parse failed:", error);
    writeJson(response, 500, {
      error: error instanceof Error ? error.message : String(error),
    });
  }
});

server.listen(port, host, () => {
  console.log(`Llama OCR parse server listening on http://${host}:${port}`);
});

async function parseOcrLines({ rawText, lines, events, currentDate }) {
  const compactedEvents = compactEvents(events);
  const compactedLines = compactLines(lines);
  const fallbackResult = buildFastParseResult({
    events: compactedEvents,
    lines: compactedLines,
    currentDate,
  });

  if (!ollamaCleanupEnabled || fallbackResult.meetings.length > 0) {
    return fallbackResult;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), requestTimeoutMs);
  let ollamaResponse;
  try {
    ollamaResponse = await fetch(`${ollamaBaseUrl}/api/generate`, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        system: systemPrompt(),
        prompt: JSON.stringify({
          currentDate,
          rawText: events.length ? "" : rawText.slice(0, 5000),
          events: compactedEvents,
          lines: events.length ? compactedLines.slice(0, 80) : compactedLines,
        }),
        stream: false,
        format: "json",
        options: {
          temperature: 0,
        },
      }),
    });
  } catch (error) {
    if (error?.name === "AbortError") {
      console.warn(
        `Ollama request timed out after ${requestTimeoutMs / 1000}s; using fast OCR parser fallback.`,
      );
      return fallbackResult;
    }
    if (error?.cause?.code === "ECONNREFUSED") {
      console.warn(
        `Could not connect to Ollama at ${ollamaBaseUrl}; using fast OCR parser fallback.`,
      );
      return fallbackResult;
    }
    console.warn("Ollama cleanup failed; using fast OCR parser fallback.", error);
    return fallbackResult;
  } finally {
    clearTimeout(timeout);
  }

  const raw = await ollamaResponse.text();
  if (!ollamaResponse.ok) {
    console.warn(
      `Ollama error ${ollamaResponse.status}; using fast OCR parser fallback: ${raw}`,
    );
    return fallbackResult;
  }

  let parsed;
  try {
    const data = JSON.parse(raw);
    const content = data.response?.trim();
    if (!content) {
      return fallbackResult;
    }
    parsed = JSON.parse(content);
  } catch (error) {
    console.warn("Could not parse Ollama JSON; using fast OCR parser fallback.", error);
    return fallbackResult;
  }

  if (!Array.isArray(parsed.meetings) || parsed.meetings.length === 0) {
    return fallbackResult;
  }

  return {
    meetings: parsed.meetings
      .map((meeting, index) =>
        normalizeMeeting(meeting, findMatchingEvent(meeting, index, compactedEvents)),
      )
      .filter(Boolean),
  };
}

function buildFastParseResult({ events, lines, currentDate }) {
  const meetings = events
    .map((event) => meetingFromEvent(event))
    .filter(Boolean);

  if (meetings.length > 0) {
    return { meetings };
  }

  return { meetings: [] };
}

function meetingFromEvent(event) {
  if (!validIsoDate(event.inferredDate) || !validTime(event.inferredStartTime)) {
    return null;
  }

  const title = bestTitleFromLines(event.lines);
  if (!title) {
    return null;
  }
  const hasExplicitTime = eventLinesContainTime(event.lines);

  return {
    title,
    date: event.inferredDate,
    start_time: event.inferredStartTime,
    end_time: null,
    reason: hasExplicitTime
      ? "Detected from OCR text grouped inside a calendar event rectangle. Time was read from event text."
      : "Detected from OCR text grouped inside a calendar event rectangle. Time was inferred from calendar position.",
    confidence: hasExplicitTime ? 0.9 : 0.76,
  };
}

function eventLinesContainTime(lines) {
  return lines.some((line) =>
    /\b([01]?\d|2[0-3])(?::[0-5]\d)?\s*(am|pm)\b/i.test(String(line || "")),
  );
}

function meetingFromLine(line, currentDate) {
  const title = cleanTitle(line.text);
  if (!title || looksLikeNonMeetingText(title)) {
    return null;
  }

  return {
    title,
    date: validIsoDate(currentDate) ? currentDate : "",
    start_time: "",
    end_time: null,
    reason: "Detected from OCR text; date and time need review.",
    confidence: 0.35,
  };
}

function bestTitleFromLines(lines) {
  const cleaned = lines
    .map(cleanTitle)
    .filter((line) => line && !looksLikeNonMeetingText(line));

  if (cleaned.length === 0) {
    return "";
  }

  return cleaned.sort((a, b) => titleScore(b) - titleScore(a))[0];
}

function cleanTitle(value) {
  const cleaned = String(value || "")
    .replace(/https?:\/\/\S+/gi, "")
    .replace(fuzzyUrlSuffixPattern(), "")
    .replace(fuzzyMeetingPlatformSuffixPattern(), "")
    .replace(leadingAttachedTimePattern(), "")
    .replace(outlookContinuationPattern(), "")
    .replace(/\s+/g, " ")
    .replace(/^[•*\-–—\s]+/, "")
    .replace(/\b(all day)\b/gi, "")
    .replace(/\b([01]?\d|2[0-3])(?::[0-5]\d)?\s*(am|pm)\b/gi, "")
    .replace(/\b\d+(\.\d+)?\s*(min|mins|minute|minutes|hr|hrs|hour|hours)\b/gi, "")
    .replace(/\s+/g, " ")
    .replace(/[;,\s]+$/g, "")
    .trim();
  return normalizeCommonOcrWords(cleaned);
}

function titleScore(title) {
  const normalized = title.toLowerCase();
  let score = title.length;
  if (/\b(meeting|stand[- ]?up|review|session|call|sync|lunch|learn|update|appointment|class|lecture|lab|exam|office hours)\b/.test(normalized)) {
    score += 30;
  }
  if (/^\d/.test(normalized)) {
    score -= 25;
  }
  if (looksLikeDuration(normalized)) {
    score -= 80;
  }
  return score;
}

function looksLikeNonMeetingText(value) {
  const text = String(value || "").trim().toLowerCase();
  if (!text || text.length < 3 || text.length > 90) {
    return true;
  }
  if (!/[a-z]/i.test(text)) {
    return true;
  }
  if (looksLikeDuration(text)) {
    return true;
  }
  if (looksLikeBadOcrTitle(text)) {
    return true;
  }
  if (/^([01]?\d|2[0-3])(?::[0-5]\d)?\s*(am|pm)?$/.test(text)) {
    return true;
  }
  if (/^(mon|tue|wed|thu|fri|sat|sun)\w*(\s+\d{1,2}([/-]\d{1,2})?)?$/.test(text)) {
    return true;
  }
  if (outlookContinuationPattern().test(text)) {
    return true;
  }
  if (/^(mo|tu|we|th|fr|sa|su)(\s+(mo|tu|we|th|fr|sa|su))*$/.test(text)) {
    return true;
  }
  return /\b(outlook|search|today|new event|work week|week|month|calendar|all day|filter|share|print|settings)\b/.test(text);
}

function outlookContinuationPattern() {
  return /\bto\s+(jan|feb|mar|apr|may|jun|jn|jul|aug|sep|sept|oct|nov|dec)\w*\.?\s+\d{1,2}\s*[-\u2013\u2014>]?\s*$/i;
}

function leadingAttachedTimePattern() {
  return /^\s*\d{1,2}\s*(?::\s*\d{2})?\s*(a\.?m\.?|p\.?m\.?)\s*/i;
}

function fuzzyMeetingPlatformSuffixPattern() {
  return /\b(microsoft\s+teams?|microsoft|microso[l1]|microst|mierosoft|microsol|teamal|zoom|zoo?m)\b.*$/i;
}

function fuzzyMicrosoftWordPattern() {
  return /\b(microsoft\s+teams?|microsoft|microso[l1]|microst|mierosoft|microsol|teamal)\b/i;
}

function fuzzyUrlSuffixPattern() {
  return /\b(h?t?t?p?s?|hps|tps|ttps|titps|itps)[/:;][^\s]*.*$/i;
}

function strongMeetingWordPattern() {
  return /\b(meeting|stand[- ]?up|review|discussion|sync|touch|base|check[- ]?in|office|hours|board|deck|weekly|daily|okr|sourcing|legal|coreops)\b/i;
}

function looksLikeBadOcrTitle(value) {
  const text = String(value || "").trim().toLowerCase();
  if (!text) {
    return true;
  }
  if (/^(asopm|a?so\s?p?m)$/.test(text)) {
    return true;
  }
  if (/^(a?toah|atoah|hannah|hanan)\s+[a-z]+$/.test(text)) {
    return true;
  }
  if (fuzzyMicrosoftWordPattern().test(text)) {
    return true;
  }

  const letters = (text.match(/[a-z]/g) || []).length;
  const separators = (text.match(/[\/\\:_]/g) || []).length;
  const vowels = (text.match(/[aeiou]/g) || []).length;
  if (letters >= 5 && vowels <= 1) {
    return true;
  }
  if (separators >= 2 && !strongMeetingWordPattern().test(text)) {
    return true;
  }
  return false;
}

function normalizeCommonOcrWords(value) {
  return String(value || "")
    .replace(/\bDeily\b/gi, "Daily")
    .replace(/\bWokly\b/gi, "Weekly")
    .replace(/\breganding\b/gi, "regarding")
    .replace(/\bche?dk\b/gi, "check")
    .replace(/\bComplek\b/gi, "Complex")
    .replace(/\bweekh\b/gi, "weekly")
    .replace(/\s+/g, " ")
    .replace(/[;,\s]+$/g, "")
    .trim();
}

function looksLikeDuration(value) {
  return /^\d+(\.\d+)?\s*(min|mins|minute|minutes|hr|hrs|hour|hours)$/.test(
    String(value || "").trim().toLowerCase(),
  );
}

function systemPrompt() {
  return [
    "You clean OCR output from an Outlook week-calendar screenshot.",
    "Return only real meetings/classes/events visible in the calendar grid.",
    "Prefer the provided events array. Each event is a detected colored calendar rectangle with OCR lines inside it.",
    "Usually each event block should become one meeting. Use raw OCR lines only for date/time context or when events is empty.",
    "Each event may include inferredDate and inferredStartTime calculated from the calendar header row and left time axis. Use those exact values unless the event text clearly proves they are wrong.",
    "When you return a meeting from an event block, include event_index with that event's index.",
    "Do not infer AM/PM from event-title text. Use the calendar axis/inferredStartTime for AM/PM.",
    "Meeting titles usually look like short phrases such as 'Team Stand-up', 'Sales Update', 'Project Plan Review', 'Lunch & Learn', 'Server Game', or 'Doctor Appointment'.",
    "A duration line like '1 hour' or '2 hours' belongs to the event above it and is never a meeting title.",
    "Reject weekday headers, dates, month labels, time labels, navigation text, UI labels, empty slots, and OCR fragments like 'MO TU WE' or 'Thu 6/12'.",
    "Use OCR bounding boxes to infer the day column and time row when possible.",
    "If a line is just a header/date/time label, do not return it as a meeting.",
    "If there are no clear meetings, return an empty meetings array.",
    "Use ISO dates as YYYY-MM-DD and 24-hour start_time as HH:MM.",
    "If a date or time is uncertain, make the best estimate from the grid and lower confidence.",
    "Return a JSON object exactly like: {\"meetings\":[{\"event_index\":0,\"title\":\"...\",\"date\":\"YYYY-MM-DD\",\"start_time\":\"HH:MM\",\"end_time\":null,\"reason\":\"...\",\"confidence\":0.0}]}",
  ].join(" ");
}

function compactEvents(events) {
  return events
    .filter((event) => event && Array.isArray(event.lines) && event.lines.length)
    .slice(0, 80)
    .map((event, index) => ({
      index,
      text: String(event.text || event.lines.join("\n")).slice(0, 300),
      lines: event.lines.map((line) => String(line).slice(0, 120)),
      left: Number(event.left || 0),
      top: Number(event.top || 0),
      right: Number(event.right || 0),
      bottom: Number(event.bottom || 0),
      centerX: Number(event.centerX || 0),
      centerY: Number(event.centerY || 0),
      inferredDate: String(event.inferredDate || ""),
      inferredStartTime: String(event.inferredStartTime || ""),
    }));
}

function compactLines(lines) {
  return lines
    .filter((line) => line && typeof line.text === "string" && line.text.trim())
    .slice(0, 160)
    .map((line, index) => ({
      index,
      text: String(line.text).slice(0, 120),
      left: Number(line.left || 0),
      top: Number(line.top || 0),
      right: Number(line.right || 0),
      bottom: Number(line.bottom || 0),
      centerX: Number(line.centerX || 0),
      centerY: Number(line.centerY || 0),
    }));
}

function findMatchingEvent(meeting, fallbackIndex, events) {
  if (!Array.isArray(events) || events.length === 0) {
    return null;
  }

  const explicitIndex = Number(meeting?.event_index);
  if (Number.isInteger(explicitIndex) && events[explicitIndex]) {
    return events[explicitIndex];
  }

  const title = String(meeting?.title || "").toLowerCase();
  if (title) {
    const titleWords = title
      .split(/[^a-z0-9]+/)
      .filter((word) => word.length > 2);
    const match = events.find((event) => {
      const eventText = String(event.text || "").toLowerCase();
      return titleWords.length > 0 && titleWords.every((word) => eventText.includes(word));
    });
    if (match) {
      return match;
    }
  }

  return events[fallbackIndex] || null;
}

function normalizeMeeting(meeting, matchedEvent = null) {
  if (!meeting || typeof meeting !== "object") {
    return null;
  }

  const title = String(meeting.title || "").trim();
  if (!title) {
    return null;
  }

  const inferredDate = validIsoDate(matchedEvent?.inferredDate)
    ? matchedEvent.inferredDate
    : null;
  const inferredStartTime = validTime(matchedEvent?.inferredStartTime)
    ? matchedEvent.inferredStartTime
    : null;

  return {
    title,
    date: inferredDate || String(meeting.date || ""),
    start_time: inferredStartTime || String(meeting.start_time || ""),
    end_time: meeting.end_time == null ? null : String(meeting.end_time),
    reason: String(meeting.reason || "Filtered from OCR by Llama"),
    confidence: clamp(Number(meeting.confidence || 0.7), 0.1, 0.98),
  };
}

function validIsoDate(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function validTime(value) {
  return typeof value === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(value);
}

function clamp(value, min, max) {
  if (Number.isNaN(value)) {
    return min;
  }
  return Math.min(max, Math.max(min, value));
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1_000_000) {
        reject(new Error("Request body too large"));
        request.destroy();
      }
    });
    request.on("end", () => {
      try {
        resolve(JSON.parse(body || "{}"));
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function writeJson(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(JSON.stringify(value));
}

function loadEnvFile() {
  if (!existsSync(".env")) {
    return;
  }

  const lines = readFileSync(".env", "utf8").split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    const separatorIndex = trimmed.indexOf("=");
    if (separatorIndex === -1) {
      continue;
    }

    const key = trimmed.slice(0, separatorIndex).trim();
    const rawValue = trimmed.slice(separatorIndex + 1).trim();
    if (!key || process.env[key] != null) {
      continue;
    }

    process.env[key] = stripOptionalQuotes(rawValue);
  }
}

function stripOptionalQuotes(value) {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }
  return value;
}
