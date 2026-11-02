(function () {
  var root = document.documentElement;
  var toggle = document.getElementById("themeToggle");

  function syncThemeLabel() {
    if (!toggle) return;
    var dark = root.dataset.theme === "dark";
    toggle.setAttribute("aria-label", dark ? "切换到浅色模式" : "切换到深色模式");
  }

  if (toggle) {
    toggle.addEventListener("click", function () {
      var dark = root.dataset.theme === "dark";
      if (dark) {
        delete root.dataset.theme;
      } else {
        root.dataset.theme = "dark";
      }
      try {
        localStorage.setItem("subnow-theme", dark ? "light" : "dark");
      } catch (error) {}
      syncThemeLabel();
    });
    syncThemeLabel();
  }

  document.querySelectorAll("[data-copy]").forEach(function (button) {
    button.addEventListener("click", function () {
      var text = button.getAttribute("data-copy");
      var done = function () {
        var original = "复制";
        button.textContent = "已复制";
        window.setTimeout(function () {
          button.textContent = original;
        }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(function () {
          fallbackCopy(text, done);
        });
      } else {
        fallbackCopy(text, done);
      }
    });
  });

  function fallbackCopy(text, done) {
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand("copy");
      done();
    } catch (error) {}
    document.body.removeChild(area);
  }
})();
