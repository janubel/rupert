import { Controller } from '@hotwired/stimulus';
export default class extends Controller {
  static targets = ['button'];
  connect() {
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('/employee/service-worker.js', { scope: '/' }).catch(() => {});
    this.capture = event => { event.preventDefault(); this.prompt = event; this.buttonTarget.hidden = false; };
    window.addEventListener('beforeinstallprompt', this.capture);
  }
  disconnect() { window.removeEventListener('beforeinstallprompt', this.capture); }
  async install() { if (this.prompt) { await this.prompt.prompt(); this.prompt = null; this.buttonTarget.hidden = true; } }
}
