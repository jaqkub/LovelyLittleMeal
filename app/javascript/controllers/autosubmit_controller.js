import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input"]

  submit() {
    clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      if (this.element.requestSubmit) {
        this.element.requestSubmit()
      } else {
        this.element.submit()
      }
    }, 300)
  }
}
