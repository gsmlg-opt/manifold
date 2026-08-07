export const ConversationRow = {
  mounted() {
    this._onClick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      const threadId = this.el.dataset.threadId;
      if (!threadId) return;
      const modifier = event.ctrlKey || event.metaKey ? "true" : "false";
      this.pushEvent("select-conversation", {
        "thread-id": threadId,
        modifier,
      });
    };
    this.el.addEventListener("click", this._onClick);
  },
  destroyed() {
    this.el.removeEventListener("click", this._onClick);
  },
};
