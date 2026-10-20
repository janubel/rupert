// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails";
import { registerStyledConfirm } from "lib/styled_confirm";
registerStyledConfirm(window.Turbo);
import "controllers";
import "chartkick";
import "Chart.bundle";
import "lib/form_busy";

// Charts follow the app theme: axis text and grid come from the palette tokens,
// so they stay legible in both light and dark appearances.
const themeCharts = () => {
  const Chart = window.Chart;
  if (!Chart) return;
  const style = getComputedStyle(document.documentElement);
  const text = style.getPropertyValue("--color-mocha").trim();
  const grid = style.getPropertyValue("--color-fog").trim();
  if (text) Chart.defaults.color = text;
  if (grid) Chart.defaults.borderColor = grid;
};
themeCharts();
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", themeCharts);
