import { Controller } from "@hotwired/stimulus"

// Auto-scrolls chat messages container to bottom when new messages are added
// Shows/hides loading indicator during message processing
// Uses MutationObserver to detect when new content is appended via Turbo Stream
export default class extends Controller {
  static targets = ["loading", "messages"]

  connect() {
    // Scroll to bottom on initial load
    this.scrollToBottom()
    
    // Flag to prevent scroll operations during loading indicator changes
    this.isShowingLoading = false
    
    // Store bound functions for proper cleanup
    this.boundShowLoading = this.showLoading.bind(this)
    this.boundHideLoading = this.hideLoading.bind(this)
    
    // Use event delegation for form submission - works even when form is replaced
    // Listen on the controller element so it persists across form replacements
    this.element.addEventListener("turbo:submit-start", this.boundShowLoading)
    this.element.addEventListener("turbo:submit-end", this.boundHideLoading)
    
    // Set up MutationObserver to watch for new child elements (new messages)
    this.observer = new MutationObserver((mutations) => {
      // Skip scroll operations if we're in the middle of showing loading
      if (this.isShowingLoading) return
      
      // Check if new messages were added (not just the loading indicator or empty message removal)
      const hasNewMessages = mutations.some(mutation => 
        Array.from(mutation.addedNodes).some(node => {
          if (node.nodeType !== 1) return false
          // Ignore loading indicator and empty message
          if (node.id?.includes('chat-loading') || node.id?.includes('empty-chat-message')) return false
          // Check if it's a message bubble (has message-bubble class)
          return node.classList?.contains('message-bubble') || 
                 node.querySelector?.('.message-bubble') !== null
        })
      )
      
      if (hasNewMessages) {
        // Hide loading indicator when new messages arrive
        this.hideLoading()
        // Scroll to bottom after a brief delay to ensure DOM is fully updated
        setTimeout(() => {
          this.scrollToBottom()
        }, 50)
      }
      // Don't scroll for other mutations (like loading indicator changes)
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
    // Remove event listeners using stored bound functions
    if (this.boundShowLoading) {
      this.element.removeEventListener("turbo:submit-start", this.boundShowLoading)
    }
    if (this.boundHideLoading) {
      this.element.removeEventListener("turbo:submit-end", this.boundHideLoading)
    }
  }

  showLoading() {
    // Show loading indicator when form is submitted
    if (this.hasLoadingTarget && this.hasMessagesTarget) {
      // Set flag to prevent MutationObserver from interfering
      this.isShowingLoading = true
      
      // Store exact scroll position BEFORE any DOM changes
      const container = this.messagesTarget
      const scrollTop = container.scrollTop
      const wasAtBottom = this.isAtBottom()
      
      // Temporarily disable scroll restoration to prevent jumps
      const originalScrollRestoration = container.style.scrollBehavior
      container.style.scrollBehavior = 'auto'
      
      // Show loading indicator - use visibility instead of display to avoid layout shift
      this.loadingTarget.style.visibility = 'visible'
      this.loadingTarget.style.opacity = '0'
      this.loadingTarget.classList.remove("d-none")
      
      // Force a reflow
      void container.offsetHeight
      
      // Immediately restore scroll position multiple times to prevent any jumps
      container.scrollTop = scrollTop
      requestAnimationFrame(() => {
        container.scrollTop = scrollTop
        requestAnimationFrame(() => {
          container.scrollTop = scrollTop
          
          // Fade in the loading indicator
          this.loadingTarget.style.opacity = '1'
          this.loadingTarget.style.transition = 'opacity 0.2s'
          
          // Restore scroll behavior
          container.style.scrollBehavior = originalScrollRestoration
          
          // Only scroll to bottom if user was already at bottom
          if (wasAtBottom) {
            // Small delay to ensure loading indicator is visible, then scroll
            setTimeout(() => {
              this.isShowingLoading = false
              this.scrollToBottom()
            }, 150)
          } else {
            // Keep scroll position, just re-enable observer
            setTimeout(() => {
              this.isShowingLoading = false
            }, 50)
          }
        })
      })
    }
  }
  
  isAtBottom() {
    // Check if user is near the bottom of the chat (within 100px)
    if (!this.hasMessagesTarget) return true
    const container = this.messagesTarget
    const threshold = 100
    return (container.scrollHeight - container.scrollTop - container.clientHeight) < threshold
  }

  hideLoading() {
    // Hide loading indicator when response arrives
    if (this.hasLoadingTarget) {
      // Fade out then hide
      this.loadingTarget.style.opacity = '0'
      this.loadingTarget.style.transition = 'opacity 0.2s'
      
      setTimeout(() => {
        this.loadingTarget.classList.add("d-none")
        this.loadingTarget.style.visibility = ''
        this.loadingTarget.style.opacity = ''
        this.loadingTarget.style.transition = ''
      }, 200)
    }
  }

  scrollToBottom() {
    // Scroll to the bottom of the messages container smoothly
    if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }
}

