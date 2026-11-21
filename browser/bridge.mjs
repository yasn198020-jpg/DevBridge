import { chromium } from "playwright";
import { readFileSync } from "node:fs";
import readline from "node:readline";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const settings = JSON.parse(readFileSync(path.join(root, "config/settings.json"), "utf8"));
const cdpUrl = process.env.DEVBRIDGE_CDP_URL || settings.browser?.cdpUrl || "http://127.0.0.1:9222";
const chatUrl = process.env.DEVBRIDGE_CHAT_URL || settings.browser?.chatUrl || "https://chatgpt.com/";
let browser;
let context;
let page;

function output(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

async function ensureBrowser() {
  if (page && !page.isClosed()) return;

  browser = await chromium.connectOverCDP(cdpUrl);
  const contexts = browser.contexts();
  if (!contexts.length) {
    throw new Error("CDP connected, but the browser has no accessible context.");
  }

  context = contexts[0];
  const pages = context.pages();
  page = pages.find(candidate => {
    try {
      return new URL(candidate.url()).origin === new URL(chatUrl).origin;
    } catch {
      return false;
    }
  });

  if (!page) {
    const openPages = pages.map(candidate => candidate.url()).filter(Boolean);
    throw new Error(
      "CDP connected, but no ChatGPT tab was found. Open ChatGPT in this browser first. " +
      "Visible pages: " + (openPages.join(", ") || "(none)")
    );
  }

  await page.waitForLoadState("domcontentloaded").catch(() => {});
}

async function lastAssistantMessage() {
  const messages = page.locator('[data-message-author-role="assistant"]');
  const count = await messages.count();
  if (!count) return "";
  const last = messages.nth(count - 1);
  const markdown = last.locator(".markdown");
  if (await markdown.count()) return (await markdown.last().innerText()).trim();
  return (await last.innerText()).trim();
}

async function sendMessage(text) {
  const editor = page.locator("#prompt-textarea").last();
  let activeEditor;
  if (await editor.count()) activeEditor = editor;
  else activeEditor = page.locator('[contenteditable="true"]').last();
  if (!(await activeEditor.count())) {
    throw new Error("ChatGPT composer not found; UI may have changed.");
  }
  await activeEditor.fill(text);
  const sendButton = page.locator('button[data-testid="send-button"]');
  if (await sendButton.count() && await sendButton.last().isEnabled()) {
    await sendButton.last().click();
  } else {
    await activeEditor.press("Enter");
  }
}

async function handle(command) {
  if (command.op === "quit") {
    output({ ok: true, disconnected: true });
    // Do not close the user's browser, context, pages, or tabs.
    // The parent closes stdin and terminates this bridge process after this reply.
    browser = undefined;
    context = undefined;
    page = undefined;
    return;
  }

  await ensureBrowser();
  switch (command.op) {
    case "snapshot": {
      const messages = page.locator('[data-message-author-role]');
      const count = await messages.count();
      let conversationCharacters = 0;
      for (let i = 0; i < count; i++) {
        conversationCharacters += (await messages.nth(i).innerText()).length;
      }
      output({
        ok: true,
        url: page.url(),
        assistantText: await lastAssistantMessage(),
        conversationCharacters,
        conversationMessageCount: count
      });
      return;
    }
    case "send":
      if (typeof command.text !== "string" || !command.text.trim()) {
        throw new Error("send requires text.");
      }
      await sendMessage(command.text);
      output({ ok: true });
      return;
    case "newchat": {
      await page.goto(chatUrl, { waitUntil: "domcontentloaded" });
      await page.waitForTimeout(1200);
      const remainingMessages = await page.locator('[data-message-author-role]').count();
      if (remainingMessages > 0) {
        throw new Error("ChatGPT did not open a blank conversation; refusing to send handoff into the previous chat.");
      }
      output({ ok: true, url: page.url() });
      return;
    }
    default:
      throw new Error("Unknown operation: " + command.op);
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of rl) {
  if (!line.trim()) continue;
  try {
    await handle(JSON.parse(line));
  } catch (error) {
    output({ ok: false, error: String(error?.message || error) });
  }
}
