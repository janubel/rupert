# frozen_string_literal: true

# Pin npm packages by running ./bin/importmap

pin 'application'
pin '@hotwired/turbo-rails', to: 'turbo.min.js'
pin '@hotwired/stimulus', to: 'stimulus.min.js'
pin '@hotwired/stimulus-loading', to: 'stimulus-loading.js'
pin 'chartkick', to: 'chartkick.js'
pin 'Chart.bundle', to: 'Chart.bundle.js'
# Screenshots for the ladybug report; loaded only when someone sends one.
pin 'html2canvas-pro', to: 'html2canvas-pro.js', preload: false
pin_all_from 'app/javascript/controllers', under: 'controllers'
pin_all_from 'app/javascript/lib', under: 'lib'
