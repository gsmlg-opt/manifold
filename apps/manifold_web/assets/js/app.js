import "phoenix_html";
import "@duskmoon-dev/el-badge/register";
import "@duskmoon-dev/el-card/register";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import * as DuskmoonHooks from "phoenix_duskmoon/hooks";
import "./datetime.js";
import { ConversationRow } from "./conversation_row.js";

window.addEventListener("phx:focus-oauth-provider", ({ detail: { provider } }) => {
  document.getElementById(`oauth-provider-${provider}-client-id`)?.focus();
});

const THEME_STORAGE_KEY = "theme";

function resolveAutoTheme() {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "moonlight" : "sunshine";
}

function applyTheme(theme) {
  const resolved = !theme || theme === "default" ? resolveAutoTheme() : theme;
  document.documentElement.setAttribute("data-theme", resolved);
}

function readStoredTheme() {
  try {
    return localStorage.getItem(THEME_STORAGE_KEY);
  } catch (_error) {
    return null;
  }
}

// Keep auto mode responsive to the OS even outside Appearance settings.
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if ((readStoredTheme() || "default") === "default") applyTheme("default");
});

function writeStoredTheme(theme) {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, theme);
  } catch (_error) {
    // ignore quota / private mode failures
  }
}

const ThemePreference = {
  mounted() {
    const theme = readStoredTheme() || "default";
    applyTheme(theme);
    this.syncButtons(theme);

    this._clickListener = (event) => {
      const button = event.target.closest("button.segment-item");
      if (!button || !this.el.contains(button) || button.disabled) return;

      const next = button.value;
      writeStoredTheme(next);
      applyTheme(next);
      this.syncButtons(next);
      this.pushEvent("theme_changed", { theme: next });
    };
    this.el.addEventListener("click", this._clickListener);
  },
  destroyed() {
    this.el.removeEventListener("click", this._clickListener);
  },
  syncButtons(theme) {
    this.el.querySelectorAll("button.segment-item").forEach((button) => {
      const active = theme === button.value;
      button.classList.toggle("segment-item-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
  },
};

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ...DuskmoonHooks, ThemePreference, ConversationRow },
});

liveSocket.connect();
window.liveSocket = liveSocket;
