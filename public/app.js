document.addEventListener("toggle", async (event) => {
  const details = event.target;
  if (!(details instanceof HTMLDetailsElement) || !details.open || details.dataset.loaded) return;

  const container = details.querySelector(".log-container");
  if (!container) return;

  container.innerHTML = '<span class="muted">Loading log entries…</span>';
  try {
    const response = await fetch(details.dataset.logsUrl, {
      headers: { Accept: "text/html" }
    });
    if (!response.ok) throw new Error(`Request failed (${response.status})`);
    container.innerHTML = await response.text();
    details.dataset.loaded = "true";
  } catch (error) {
    container.textContent = `Unable to load logs: ${error.message}`;
  }
}, true);