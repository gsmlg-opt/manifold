import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import * as DuskmoonHooks from "phoenix_duskmoon/hooks";
import "./datetime.js";
import { ConversationRow } from "./conversation_row.js";

// Prefer localStorage over an empty/default server theme so LiveView remounts
// do not clobber an explicit sunshine/moonlight choice with OS auto.
const UpstreamThemeSwitcher = DuskmoonHooks.ThemeSwitcher;
const THEME_STORAGE_KEY = "theme";

function resolveAutoTheme() {
  return window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "moonlight"
    : "sunshine";
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

function writeStoredTheme(theme) {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, theme);
  } catch (_error) {
    // ignore quota / private mode failures
  }
}

function resolvePreferredTheme(serverTheme) {
  const stored = readStoredTheme();
  // Only honor an explicit non-default server theme; otherwise keep local choice.
  if (serverTheme && serverTheme !== "default") return serverTheme;
  return stored || serverTheme || "default";
}

const ThemeSwitcher = {
  ...UpstreamThemeSwitcher,
  mounted() {
    const theme = resolvePreferredTheme(this.el.dataset.theme || "");
    applyTheme(theme);
    this.syncRadios(theme);

    this._mediaListener = () => {
      const current = readStoredTheme() || "default";
      if (current === "default") applyTheme("default");
    };
    window
      .matchMedia("(prefers-color-scheme: dark)")
      .addEventListener("change", this._mediaListener);

    this._changeListeners = [];
    this.el.querySelectorAll(".theme-controller-item").forEach((input) => {
      const listener = (event) => {
        const next = event.target.value;
        requestAnimationFrame(() => {
          applyTheme(next);
          writeStoredTheme(next);
          this.pushEvent("theme_changed", { theme: next });
          this.el.removeAttribute("open");
        });
      };
      input.addEventListener("change", listener);
      this._changeListeners.push({ element: input, listener });
    });
  },
  updated() {
    // With phx-update="ignore" this rarely runs; keep localStorage authoritative.
    const theme = resolvePreferredTheme(this.el.dataset.theme || "");
    applyTheme(theme);
    this.syncRadios(theme);
  },
  syncRadios(theme) {
    this.el.querySelectorAll(".theme-controller-item").forEach((input) => {
      input.checked = theme === input.value;
    });
  },
};

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ...DuskmoonHooks, ThemeSwitcher, ConversationRow },
});

liveSocket.connect();
window.liveSocket = liveSocket;
