/**
 * Formats an absolute ISO-8601 timestamp in the browser's local timezone.
 *
 * Usage:
 *   <mf-datetime datetime="2026-08-06T14:46:00.000000Z" format="datetime">
 *     2026-08-06 14:46
 *   </mf-datetime>
 *
 * `format` values:
 *   - datetime (default): YYYY-MM-DD HH:MM
 *   - date: YYYY-MM-DD
 *   - time: HH:MM
 *
 * Note: avoid class private fields/methods (#foo). duskmoon_bundler's oxc
 * transform rewrites them to @oxc-project/runtime helpers that 404 in dev,
 * which prevents app.js (and ThemeSwitcher) from evaluating at all.
 */
class MfDatetime extends HTMLElement {
  static get observedAttributes() {
    return ["datetime", "format"];
  }

  connectedCallback() {
    this.render();
  }

  attributeChangedCallback(_name, oldValue, newValue) {
    if (oldValue !== newValue && this.isConnected) {
      this.render();
    }
  }

  render() {
    const value = this.getAttribute("datetime");
    if (!value) {
      this.textContent = "";
      return;
    }

    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      this.textContent = value;
      return;
    }

    this.textContent = formatLocal(date, this.getAttribute("format") || "datetime");
  }
}

function pad(n) {
  return String(n).padStart(2, "0");
}

function formatLocal(date, format) {
  const y = date.getFullYear();
  const m = pad(date.getMonth() + 1);
  const d = pad(date.getDate());
  const h = pad(date.getHours());
  const min = pad(date.getMinutes());

  switch (format) {
    case "date":
      return `${y}-${m}-${d}`;
    case "time":
      return `${h}:${min}`;
    case "datetime":
    default:
      return `${y}-${m}-${d} ${h}:${min}`;
  }
}

if (!customElements.get("mf-datetime")) {
  customElements.define("mf-datetime", MfDatetime);
}

export { MfDatetime };
