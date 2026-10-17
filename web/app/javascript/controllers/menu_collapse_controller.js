import { Controller } from "@hotwired/stimulus"

// Keeps a navigation menu open on wide screens and folded away on phones,
// so the page title is the first thing a phone shows. Open or close it with
// the summary line at any width the menu is folded.
export default class extends Controller {
  connect() {
    this.element.open = window.matchMedia("(min-width: 641px)").matches
  }
}
