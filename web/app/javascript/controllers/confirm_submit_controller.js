import { Controller } from "@hotwired/stimulus"

// Asks for confirmation before a form is submitted. The message states the
// amount, date and consequence, and is built on the server so it matches
// what will actually happen. Submitting is blocked once confirmed, so a
// double click cannot send the form twice.
export default class extends Controller {
  static values = { message: String }

  confirm(event) {
    if (this.sent) {
      event.preventDefault()
      return
    }
    if (!window.confirm(this.messageValue)) {
      event.preventDefault()
      return
    }
    this.sent = true
  }
}
