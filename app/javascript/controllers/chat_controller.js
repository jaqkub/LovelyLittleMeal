import { Controller } from "@hotwired/stimulus"

// Auto-scrolls chat messages container to bottom when new messages are added
// Shows/hides loading indicator during message processing
// Uses MutationObserver to detect when new content is appended via Turbo Stream
export default class extends Controller {
  static targets = ["loading", "messages"]

  connect() {
    // Scroll to bottom on initial load
    this.scrollToBottom()
    
    // Set up MutationObserver to watch for new child elements (new messages)
    this.observer = new MutationObserver((mutations) => {
      // Check if new messages were added (not just the loading indicator)
      const hasNewMessages = mutations.some(mutation => 
        Array.from(mutation.addedNodes).some(node => 
          node.nodeType === 1 && !node.id?.includes('chat-loading')
        )
      )
      
      if (hasNewMessages) {
        // Hide loading indicator when new messages arrive
        this.hideLoading()
      }
      
      // Use requestAnimationFrame to ensure DOM is fully updated before scrolling
      requestAnimationFrame(() => {
        this.scrollToBottom()
      })
    })
    
    // Observe changes to child elements (when messages are added)
    // Watch the messages container, not the entire controller element
    if (this.hasMessagesTarget) {
      this.observer.observe(this.messagesTarget, {
        childList: true,
        subtree: true
      })
    }
  }

  disconnect() {
    // Clean up observer when controller is disconnected
    if (this.observer) {
      this.observer.disconnect()
    }
  }

  showLoading() {
    // Show loading indicator when form is submitted
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.remove("d-none")
      this.scrollToBottom()
    }
  }

  hideLoading() {
    // Hide loading indicator when response arrives
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.add("d-none")
    }
  }

  scrollToBottom() {
    // Scroll to the bottom of the messages container smoothly
    if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }
}

