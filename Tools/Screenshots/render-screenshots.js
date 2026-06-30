#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.resolve(__dirname, "../..");
const outputDir = path.join(root, "docs/screenshots");
fs.mkdirSync(outputDir, { recursive: true });

const W = 1290;
const H = 2796;
const LEFT = 86;
const RIGHT = W - LEFT;
const FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', Helvetica, Arial, sans-serif";

const colors = {
  canvas: "#F6F7F1",
  ink: "#1A2025",
  muted: "#67747C",
  border: "#D4DBDD",
  row: "#EEF3F5",
  accent: "#0E60D6",
  green: "#117B49",
  amber: "#BE6E10",
  red: "#BE2925",
  white: "#FFFFFF"
};

function escape(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function wrap(text, maxChars) {
  const words = String(text).split(/\s+/);
  const lines = [];
  let current = "";
  for (const word of words) {
    const next = current ? `${current} ${word}` : word;
    if (next.length > maxChars && current) {
      lines.push(current);
      current = word;
    } else {
      current = next;
    }
  }
  if (current) lines.push(current);
  return lines;
}

function textBlock(x, y, text, size, weight, color, maxChars, lineHeight = Math.round(size * 1.25)) {
  const lines = wrap(text, maxChars);
  const nodes = lines.map((line, index) => (
    `<text x="${x}" y="${y + index * lineHeight}" font-family="${FONT}" font-size="${size}" font-weight="${weight}" fill="${color}">${escape(line)}</text>`
  ));
  return { svg: nodes.join("\n"), height: Math.max(lineHeight, lines.length * lineHeight) };
}

function rect(x, y, w, h, fill, stroke = null, radius = 24) {
  const strokeAttrs = stroke ? ` stroke="${stroke}" stroke-width="2"` : "";
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${radius}" fill="${fill}"${strokeAttrs}/>`;
}

function pill(x, y, label, fill, color, width = null) {
  const w = width || Math.max(168, label.length * 20 + 54);
  return `${rect(x, y, w, 58, fill, null, 29)}
  <text x="${x + w / 2}" y="${y + 38}" text-anchor="middle" font-family="${FONT}" font-size="25" font-weight="700" fill="${color}">${escape(label)}</text>`;
}

function statusBar() {
  return `
  <text x="98" y="70" font-family="${FONT}" font-size="28" font-weight="700" fill="${colors.ink}">9:41</text>
  <rect x="552" y="30" width="186" height="58" rx="29" fill="#101316"/>
  <rect x="936" y="64" width="8" height="18" rx="3" fill="${colors.ink}"/>
  <rect x="952" y="56" width="8" height="26" rx="3" fill="${colors.ink}"/>
  <rect x="968" y="48" width="8" height="34" rx="3" fill="${colors.ink}"/>
  <rect x="984" y="40" width="8" height="42" rx="3" fill="${colors.ink}"/>
  <path d="M1020 64 C1038 46, 1068 46, 1086 64" fill="none" stroke="${colors.ink}" stroke-width="5" stroke-linecap="round"/>
  <path d="M1036 80 C1046 70, 1058 70, 1068 80" fill="none" stroke="${colors.ink}" stroke-width="5" stroke-linecap="round"/>
  <rect x="1058" y="45" width="58" height="26" rx="7" fill="none" stroke="${colors.ink}" stroke-width="3"/>
  <rect x="1119" y="52" width="5" height="12" rx="2" fill="${colors.ink}"/>
  <rect x="1064" y="51" width="45" height="14" rx="4" fill="${colors.ink}"/>`;
}

function shell(content) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <rect width="${W}" height="${H}" fill="${colors.canvas}"/>
  ${statusBar()}
  ${content}
  <rect x="493" y="2746" width="304" height="12" rx="6" fill="#11161A" opacity="0.9"/>
</svg>`;
}

function card(x, y, w, h, content) {
  return `${rect(x, y, w, h, colors.white, colors.border, 26)}${content}`;
}

function header(title, subtitle, badge) {
  const h1 = textBlock(LEFT, 182, title, 64, 800, colors.ink, 18, 76);
  const sub = textBlock(LEFT, 338, subtitle, 34, 500, colors.muted, 46, 44);
  return `
  ${pill(RIGHT - 214, 174, badge, colors.white, badge === "Ready" ? colors.green : colors.amber, 214)}
  ${h1.svg}
  ${sub.svg}`;
}

function inputScreenshot() {
  const composerText = "Review the onboarding doc, send Mira the blockers by Friday, and schedule a design sync next week. Update the launch checklist before the beta build ships.";
  const lines = textBlock(LEFT + 34, 632, composerText, 34, 500, colors.ink, 45, 48);
  const modelCopy = textBlock(LEFT + 34, 1426, "Foundation Models ready. Offline fallback remains available for travel, airplane mode, and restricted networks.", 31, 500, colors.muted, 52, 42);
  return shell(`
    ${header("LocalAssist", "Workspace ready. No network session active.", "Ready")}
    ${card(LEFT, 492, RIGHT - LEFT, 604, `
      <text x="${LEFT + 34}" y="568" font-family="${FONT}" font-size="32" font-weight="800" fill="${colors.ink}">Source text</text>
      <text x="${RIGHT - 170}" y="568" font-family="${FONT}" font-size="24" font-weight="700" fill="${colors.muted}">154 chars</text>
      ${rect(LEFT + 34, 600, RIGHT - LEFT - 68, 256, "#FBFCFC", colors.border, 18)}
      ${lines.svg}
      <text x="${LEFT + 34}" y="932" font-family="${FONT}" font-size="29" font-weight="700" fill="${colors.ink}">Suggestions</text>
      <text x="${RIGHT - 82}" y="932" text-anchor="middle" font-family="${FONT}" font-size="30" font-weight="800" fill="${colors.ink}">5</text>
      <rect x="${LEFT + 34}" y="970" width="${RIGHT - LEFT - 68}" height="8" rx="4" fill="${colors.row}"/>
      <rect x="${LEFT + 34}" y="970" width="710" height="8" rx="4" fill="${colors.accent}"/>
      <circle cx="${LEFT + 744}" cy="974" r="24" fill="${colors.white}" stroke="${colors.accent}" stroke-width="8"/>
      ${pill(LEFT + 34, 1018, "Force offline fallback", colors.row, colors.ink, 368)}
    `)}
    ${rect(LEFT, 1140, RIGHT - LEFT, 92, colors.accent, null, 24)}
    <text x="${W / 2}" y="1198" text-anchor="middle" font-family="${FONT}" font-size="34" font-weight="800" fill="${colors.white}">Generate locally</text>
    ${card(LEFT, 1290, RIGHT - LEFT, 388, `
      <text x="${LEFT + 34}" y="1364" font-family="${FONT}" font-size="32" font-weight="800" fill="${colors.ink}">Status</text>
      ${modelCopy.svg}
      ${pill(LEFT + 34, 1546, "On-device first", "#EAF2FF", colors.accent, 280)}
      ${pill(LEFT + 338, 1546, "No network required", "#EAF8F1", colors.green, 320)}
    `)}
  `);
}

function summaryScreenshot() {
  const overview = textBlock(LEFT + 34, 610, "Review onboarding, send Mira launch blockers, schedule design sync, and update the checklist before beta.", 40, 750, colors.ink, 42, 54);
  const points = ["Review the onboarding doc", "Send Mira the blockers by Friday", "Schedule a design sync next week", "Update the launch checklist"];
  const pointNodes = points.map((point, index) => {
    const y = 820 + index * 76;
    return `<circle cx="${LEFT + 54}" cy="${y - 10}" r="16" fill="${colors.green}"/>
    <path d="M${LEFT + 46} ${y - 10} l7 8 l14 -18" fill="none" stroke="${colors.white}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>
    <text x="${LEFT + 88}" y="${y}" font-family="${FONT}" font-size="31" font-weight="600" fill="${colors.ink}">${escape(point)}</text>`;
  }).join("\n");
  const tasks = [
    ["Review the onboarding doc", "Low", colors.green, "reminder"],
    ["Send Mira the blockers by Friday", "High", colors.red, "messageDraft"],
    ["Schedule a design sync next week", "Medium", colors.amber, "calendarHold"]
  ].map((task, index) => {
    const y = 1310 + index * 178;
    return `${rect(LEFT + 34, y, RIGHT - LEFT - 68, 136, colors.row, null, 18)}
    <circle cx="${LEFT + 70}" cy="${y + 50}" r="12" fill="${task[2]}"/>
    <text x="${LEFT + 102}" y="${y + 54}" font-family="${FONT}" font-size="31" font-weight="800" fill="${colors.ink}">${escape(task[0])}</text>
    <text x="${LEFT + 102}" y="${y + 102}" font-family="${FONT}" font-size="25" font-weight="700" fill="${colors.muted}">${task[1]} · ${task[3]}</text>`;
  }).join("\n");
  return shell(`
    ${header("Structured output", "Predictable JSON becomes typed summaries, tasks, and action drafts.", "Offline")}
    ${card(LEFT, 492, RIGHT - LEFT, 656, `
      <text x="${LEFT + 34}" y="548" font-family="${FONT}" font-size="30" font-weight="800" fill="${colors.muted}">Summary</text>
      ${overview.svg}
      ${pointNodes}
    `)}
    ${card(LEFT, 1200, RIGHT - LEFT, 640, `
      <text x="${LEFT + 34}" y="1254" font-family="${FONT}" font-size="30" font-weight="800" fill="${colors.muted}">Suggested tasks</text>
      ${tasks}
    `)}
    ${card(LEFT, 1892, RIGHT - LEFT, 280, `
      <text x="${LEFT + 34}" y="1964" font-family="${FONT}" font-size="32" font-weight="800" fill="${colors.ink}">Fallback reason</text>
      <text x="${LEFT + 34}" y="2028" font-family="${FONT}" font-size="31" font-weight="500" fill="${colors.muted}">No on-device model adapter was configured.</text>
      ${pill(LEFT + 34, 2088, "Deterministic", "#FFF5E6", colors.amber, 260)}
    `)}
  `);
}

function actionsScreenshot() {
  const measuredCopy = textBlock(LEFT + 34, 1928, "Benchmark coverage records p50, p95, peak memory, fallback rate, and cancellation latency for repeatable regressions.", 30, 500, colors.muted, 54, 40);
  const actions = [
    ["Create reminder", "A reminder is staged locally and still needs user confirmation before it writes to Reminders.", "bell.badge"],
    ["Draft follow-up message", "A message draft is staged locally and still needs user confirmation before it opens a composer.", "paperplane"],
    ["Draft calendar hold", "A calendar hold is staged locally and still needs user confirmation before it writes to Calendar.", "calendar"]
  ].map((item, index) => {
    const y = 560 + index * 248;
    const wrapped = textBlock(LEFT + 150, y + 96, item[1], 27, 500, colors.muted, 48, 38);
    return `${rect(LEFT, y, RIGHT - LEFT, 204, colors.white, colors.border, 24)}
    <rect x="${LEFT + 34}" y="${y + 46}" width="82" height="82" rx="20" fill="#EAF2FF"/>
    <text x="${LEFT + 75}" y="${y + 101}" text-anchor="middle" font-family="${FONT}" font-size="34" font-weight="900" fill="${colors.accent}">+</text>
    <text x="${LEFT + 150}" y="${y + 60}" font-family="${FONT}" font-size="33" font-weight="800" fill="${colors.ink}">${escape(item[0])}</text>
    ${wrapped.svg}
    <text x="${RIGHT - 60}" y="${y + 110}" text-anchor="middle" font-family="${FONT}" font-size="34" font-weight="800" fill="${colors.muted}">›</text>`;
  }).join("\n");
  return shell(`
    ${header("Confirmation-first actions", "Drafts are staged locally so the user approves every system write.", "Ready")}
    ${actions}
    ${card(LEFT, 1378, RIGHT - LEFT, 360, `
      <text x="${LEFT + 34}" y="1450" font-family="${FONT}" font-size="34" font-weight="800" fill="${colors.ink}">Run metrics</text>
      ${rect(LEFT + 34, 1500, 320, 142, colors.row, null, 18)}
      <text x="${LEFT + 64}" y="1552" font-family="${FONT}" font-size="24" font-weight="800" fill="${colors.muted}">Latency</text>
      <text x="${LEFT + 64}" y="1608" font-family="${FONT}" font-size="38" font-weight="900" fill="${colors.ink}">0.4 ms</text>
      ${rect(LEFT + 386, 1500, 320, 142, colors.row, null, 18)}
      <text x="${LEFT + 416}" y="1552" font-family="${FONT}" font-size="24" font-weight="800" fill="${colors.muted}">Source</text>
      <text x="${LEFT + 416}" y="1608" font-family="${FONT}" font-size="38" font-weight="900" fill="${colors.ink}">Fallback</text>
      ${rect(LEFT + 738, 1500, 320, 142, colors.row, null, 18)}
      <text x="${LEFT + 768}" y="1552" font-family="${FONT}" font-size="24" font-weight="800" fill="${colors.muted}">Drafts</text>
      <text x="${LEFT + 768}" y="1608" font-family="${FONT}" font-size="38" font-weight="900" fill="${colors.ink}">3</text>
    `)}
    ${card(LEFT, 1790, RIGHT - LEFT, 342, `
      <text x="${LEFT + 34}" y="1862" font-family="${FONT}" font-size="34" font-weight="800" fill="${colors.ink}">Measured behavior</text>
      ${measuredCopy.svg}
      ${pill(LEFT + 34, 2046, "p50 / p95", "#EAF2FF", colors.accent, 210)}
      ${pill(LEFT + 268, 2046, "Cancellation", "#EAF8F1", colors.green, 250)}
      ${pill(LEFT + 542, 2046, "Peak memory", "#FFF5E6", colors.amber, 248)}
    `)}
  `);
}

function historyScreenshot() {
  const exportCopy = textBlock(LEFT + 34, 1954, "Benchmarks write sorted JSON for CI, README baselines, and Instruments comparisons.", 30, 500, colors.muted, 54, 40);
  const rows = [
    ["Review onboarding, send blockers, schedule design sync.", "0.3 ms · 3 tasks · 3 drafts", colors.amber],
    ["Prepare release notes and update the launch checklist.", "0.4 ms · 2 tasks · 2 drafts", colors.amber],
    ["Send Mira the Friday blockers.", "0.5 ms · 1 task · 1 draft", colors.amber]
  ].map((row, index) => {
    const y = 1138 + index * 178;
    return `${rect(LEFT + 34, y, RIGHT - LEFT - 68, 132, colors.white, colors.border, 18)}
      <circle cx="${LEFT + 76}" cy="${y + 48}" r="14" fill="${row[2]}"/>
      <text x="${LEFT + 112}" y="${y + 52}" font-family="${FONT}" font-size="30" font-weight="800" fill="${colors.ink}">${escape(row[0])}</text>
      <text x="${LEFT + 112}" y="${y + 98}" font-family="${FONT}" font-size="24" font-weight="700" fill="${colors.muted}">${escape(row[1])}</text>`;
  }).join("\n");

  return shell(`
    ${header("Performance history", "Local runs are saved privately and summarized into aggregate metrics.", "Ready")}
    ${card(LEFT, 492, RIGHT - LEFT, 426, `
      <text x="${LEFT + 34}" y="564" font-family="${FONT}" font-size="34" font-weight="800" fill="${colors.ink}">Aggregate metrics</text>
      ${rect(LEFT + 34, 628, 320, 142, colors.row, null, 18)}
      <text x="${LEFT + 64}" y="680" font-family="${FONT}" font-size="24" font-weight="800" fill="${colors.muted}">Runs</text>
      <text x="${LEFT + 64}" y="736" font-family="${FONT}" font-size="38" font-weight="900" fill="${colors.ink}">42</text>
      ${rect(LEFT + 386, 628, 320, 142, colors.row, null, 18)}
      <text x="${LEFT + 416}" y="680" font-family="${FONT}" font-size="24" font-weight="800" fill="${colors.muted}">p50</text>
      <text x="${LEFT + 416}" y="736" font-family="${FONT}" font-size="38" font-weight="900" fill="${colors.ink}">0.3 ms</text>
      ${rect(LEFT + 738, 628, 320, 142, colors.row, null, 18)}
      <text x="${LEFT + 768}" y="680" font-family="${FONT}" font-size="24" font-weight="800" fill="${colors.muted}">p95</text>
      <text x="${LEFT + 768}" y="736" font-family="${FONT}" font-size="38" font-weight="900" fill="${colors.ink}">0.6 ms</text>
      ${pill(LEFT + 34, 812, "42 fallback", "#FFF5E6", colors.amber, 230)}
      ${pill(LEFT + 288, 812, "0 model", "#EAF2FF", colors.accent, 180)}
      ${pill(LEFT + 492, 812, "3.0 avg drafts", "#EAF8F1", colors.green, 260)}
    `)}
    ${card(LEFT, 1026, RIGHT - LEFT, 714, `
      <text x="${LEFT + 34}" y="1098" font-family="${FONT}" font-size="34" font-weight="800" fill="${colors.ink}">Recent runs</text>
      ${rows}
    `)}
    ${card(LEFT, 1816, RIGHT - LEFT, 300, `
      <text x="${LEFT + 34}" y="1888" font-family="${FONT}" font-size="34" font-weight="800" fill="${colors.ink}">Export-ready telemetry</text>
      ${exportCopy.svg}
      ${pill(LEFT + 34, 2046, "JSON", "#EAF2FF", colors.accent, 156)}
      ${pill(LEFT + 214, 2046, "Throughput", "#EAF8F1", colors.green, 228)}
      ${pill(LEFT + 466, 2046, "Memory delta", "#FFF5E6", colors.amber, 256)}
    `)}
  `);
}

const screenshots = [
  ["01-assistant-home", inputScreenshot()],
  ["02-structured-summary", summaryScreenshot()],
  ["03-action-drafts-metrics", actionsScreenshot()],
  ["04-history-performance", historyScreenshot()]
];

for (const [name, svg] of screenshots) {
  const svgPath = path.join(outputDir, `${name}.svg`);
  const pngPath = path.join(outputDir, `${name}.png`);
  fs.writeFileSync(svgPath, svg);
  execFileSync("sips", ["-s", "format", "png", svgPath, "--out", pngPath], { stdio: "ignore" });
  console.log(`rendered ${path.relative(root, pngPath)}`);
}
