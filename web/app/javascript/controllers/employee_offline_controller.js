import { Controller } from '@hotwired/stimulus'

// Keep the existing network-only offline notice without an installation prompt.
export default class extends Controller {
  connect() {
    if (window.isSecureContext && 'serviceWorker' in navigator) {
      navigator.serviceWorker.register('/employee/service-worker.js', { scope: '/' }).catch(() => {})
    }
  }
}
