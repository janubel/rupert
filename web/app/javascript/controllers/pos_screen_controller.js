import { Controller } from "@hotwired/stimulus"

// Full-screen cashier (ctrax_pos). Search-as-you-type over the server-filtered product
// frame, scanner Enter, the "pick the right thing" item sheet and the cart/checkout step.
// It never prices anything: adding hands a variant id and quantity to pos-cart, which asks
// the server for the quote. Every target is optional so the two-screen demo can reuse it.
export default class extends Controller {
  static targets = [
    "search", "searchForm", "category", "results", "announce", "cart",
    "itemDialog", "itemImage", "itemCategory", "itemTitle", "itemVariant", "itemPrice", "itemStock",
    "itemStockDetail", "itemCodes", "itemVariants", "itemNote", "itemId", "itemQuantity", "itemAdd", "itemCancel",
    "imageForm", "imageProduct", "imagesDialog"
  ]
  static values = { stockFresh: { type: Boolean, default: true } }

  connect() {
    this.onKeydown = (event) => this.keydown(event)
    document.addEventListener("keydown", this.onKeydown)
    if (this.hasSearchTarget) requestAnimationFrame(() => this.focusSearch(false))
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    clearTimeout(this.timer)
  }

  // --- Keyboard -----------------------------------------------------------------------

  keydown(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return
    if (this.openDialog() || !this.hasSearchTarget) return
    const el = event.target
    if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT" || el.isContentEditable)) return
    if (event.key === "/") {
      event.preventDefault()
      this.focusSearch(true)
    } else if (event.key.length === 1 && /[\p{L}\p{N}]/u.test(event.key)) {
      // A scanner or a cashier typing with focus elsewhere: the keys belong in search.
      this.searchTarget.focus({ preventScroll: true })
    }
  }

  searchKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.enter()
    } else if (event.key === "Escape" && this.searchTarget.value) {
      event.preventDefault()
      this.searchTarget.value = ""
      this.submitSearch()
    } else if (event.key === "ArrowDown") {
      const tile = this.firstTile()
      if (tile) { event.preventDefault(); tile.focus() }
    }
  }

  focusSearch(select) {
    if (!this.hasSearchTarget || this.openDialog()) return
    this.searchTarget.focus({ preventScroll: true })
    if (select) this.searchTarget.select()
  }

  openDialog() {
    return this.element.querySelector("dialog[open]")
  }

  // --- Search -------------------------------------------------------------------------

  typed() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.submitSearch(), 180)
  }

  submitSearch() {
    clearTimeout(this.timer)
    if (this.hasSearchFormTarget) this.searchFormTarget.requestSubmit()
  }

  pickCategory(event) {
    if (!this.hasSearchFormTarget || !this.hasCategoryTarget) return
    event.preventDefault()
    this.categoryTarget.value = event.currentTarget.dataset.category || ""
    this.submitSearch()
    this.focusSearch(false)
  }

  clearSearch(event) {
    if (!this.hasSearchFormTarget) return
    event.preventDefault()
    if (this.hasSearchTarget) this.searchTarget.value = ""
    if (this.hasCategoryTarget) this.categoryTarget.value = ""
    this.submitSearch()
    this.focusSearch(false)
  }

  switchStore(event) {
    event.target.form?.requestSubmit()
  }

  // The frame answered: keep the category field in step and finish a pending Enter.
  resultsTargetConnected(element) {
    if (this.hasCategoryTarget) this.categoryTarget.value = element.dataset.category || ""
    if (this.enterPending && this.hasSearchTarget && (element.dataset.query || "") === this.term()) {
      this.enterPending = false
      this.act()
    }
  }

  term() {
    return this.hasSearchTarget ? this.searchTarget.value.trim().slice(0, 200) : ""
  }

  // Enter: an exact SKU/barcode match (a scan) goes straight in; otherwise the top result
  // opens for confirmation. Waits for the frame when results for this text are not in yet.
  enter() {
    if (this.hasResultsTarget && (this.resultsTarget.dataset.query || "") === this.term()) {
      clearTimeout(this.timer)
      this.act()
    } else {
      this.enterPending = true
      this.submitSearch()
    }
  }

  act() {
    if (!this.hasResultsTarget) return
    const exact = this.parse(this.resultsTarget.dataset.exactItem)
    if (exact) {
      if (exact.addable && this.stockFreshValue) this.addDirect(exact)
      else this.openItem(exact)
      return
    }
    const tile = this.firstTile()
    if (tile) tile.click()
    else if (this.term()) this.announce(`No product matches “${this.term()}”.`)
  }

  firstTile() {
    return this.hasResultsTarget ? this.resultsTarget.querySelector(".pos-tile") : null
  }

  addDirect(item) {
    const cart = this.cart()
    if (!cart) return
    cart.addVariant(item.id, 1)
    this.announce(`Added 1 × ${this.label(item)}${item.stock === "Out" ? " · out of stock in C-Trax" : ""}.`)
    this.backToCart()
    this.searchTarget.value = ""
    this.submitSearch()
    this.focusSearch(false)
  }

  // --- Item sheet ---------------------------------------------------------------------

  open(event) {
    event.preventDefault()
    const item = this.parse(event.currentTarget.dataset.item)
    if (item) this.openItem(item)
  }

  openItem(item) {
    if (!this.hasItemDialogTarget) return
    this.item = item
    this.fillItem(item)
    if (this.hasItemQuantityTarget) this.itemQuantityTarget.value = "1"
    if (!this.itemDialogTarget.open) this.itemDialogTarget.showModal()
    const focus = this.hasItemAddTarget && !this.itemAddTarget.disabled ? this.itemAddTarget : (this.hasItemCancelTarget ? this.itemCancelTarget : null)
    focus?.focus()
  }

  fillItem(item) {
    const text = (name, value) => { if (this[`has${name}Target`]) this[`${name.charAt(0).toLowerCase()}${name.slice(1)}Target`].textContent = value || "" }
    if (this.hasItemImageTarget) {
      if (item.image) this.itemImageTarget.src = item.image
      else this.itemImageTarget.removeAttribute("src")
      this.itemImageTarget.alt = this.label(item)
    }
    text("ItemCategory", item.category)
    text("ItemTitle", item.title)
    text("ItemVariant", item.variant || (item.name !== item.title ? item.name : ""))
    text("ItemPrice", item.price)
    text("ItemStockDetail", item.stock_detail)
    if (this.hasItemStockTarget) {
      this.itemStockTarget.className = `${item.stock_tone} pos-stock`
      this.itemStockTarget.textContent = item.stock
    }
    text("ItemCodes", [item.sku && `SKU ${item.sku}`, item.barcode && `Barcode ${item.barcode}`].filter(Boolean).join(" · "))
    if (this.hasItemIdTarget) this.itemIdTarget.value = item.id
    const blocked = !item.addable || !this.stockFreshValue
    if (this.hasItemAddTarget) this.itemAddTarget.disabled = blocked
    if (this.hasItemNoteTarget) {
      const note = !item.addable ? "This price must be reviewed in C-Trax before it can be sold here."
        : !this.stockFreshValue ? "A new stock read is required before items can be added."
        : item.stock === "Out" ? "Out of stock in C-Trax. Checkout refuses it unless stock is corrected."
        : item.stock === "Unknown" ? "Stock is unknown in C-Trax. Checkout needs a known quantity."
        : ""
      this.itemNoteTarget.textContent = note
      this.itemNoteTarget.hidden = !note
    }
    this.renderVariants(item)
    if (this.hasImageFormTarget && item.image_link_url) {
      this.imageFormTarget.action = item.image_link_url
      if (this.hasImageProductTarget) this.imageProductTarget.value = item.image_product_id || ""
    }
  }

  renderVariants(item) {
    if (!this.hasItemVariantsTarget) return
    const variants = this.item?.variants || item.variants || []
    this.itemVariantsTarget.replaceChildren()
    this.itemVariantsTarget.hidden = variants.length < 2
    variants.forEach((variant) => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = "pos-chip pos-variant"
      chip.dataset.variantId = variant.id
      chip.dataset.action = "pos-screen#pickVariant"
      chip.setAttribute("aria-pressed", String(variant.id === item.id))
      const name = document.createElement("span")
      name.textContent = variant.variant || variant.name
      const price = document.createElement("span")
      price.className = "pos-variant-price"
      price.textContent = variant.price
      chip.append(name, price)
      if (variant.stock === "Out") chip.classList.add("pos-variant-out")
      this.itemVariantsTarget.append(chip)
    })
  }

  pickVariant(event) {
    const variants = this.item?.variants || []
    const chosen = variants.find((variant) => variant.id === event.currentTarget.dataset.variantId)
    if (!chosen) return
    this.item = { ...chosen, variants }
    this.fillItem(this.item)
    this.itemVariantsTarget.querySelector(`[data-variant-id="${CSS.escape(chosen.id)}"]`)?.focus()
  }

  stepQuantity(event) {
    if (!this.hasItemQuantityTarget) return
    const current = parseInt(this.itemQuantityTarget.value, 10) || 1
    const next = Math.min(999, Math.max(1, current + Number(event.currentTarget.dataset.delta || 0)))
    this.itemQuantityTarget.value = String(next)
  }

  // Runs after pos-cart#add on the same submit: close the sheet and get ready for the next item.
  added(event) {
    if (!event.target.checkValidity()) return
    const quantity = this.hasItemQuantityTarget ? this.itemQuantityTarget.value : "1"
    if (this.item) this.announce(`Added ${quantity} × ${this.label(this.item)}.`)
    this.backToCart()
    this.itemDialogTarget.close()
  }

  closeItem() {
    if (this.hasItemDialogTarget) this.itemDialogTarget.close()
  }

  backdropClose(event) {
    if (event.target === event.currentTarget) event.currentTarget.close()
  }

  itemClosed() {
    this.focusSearch(true)
  }

  openImages(event) {
    event.currentTarget.closest("details")?.removeAttribute("open")
    if (this.hasImagesDialogTarget) this.imagesDialogTarget.showModal()
  }

  closeImages() {
    if (this.hasImagesDialogTarget) this.imagesDialogTarget.close()
  }

  // --- Cart and checkout steps --------------------------------------------------------

  checkout() {
    if (!this.hasCartTarget) return
    this.cartTarget.dataset.step = "checkout"
    const first = this.cartTarget.querySelector(".pos-checkout select:not([disabled]), .pos-checkout .pos-tender:not([disabled]), .pos-checkout .btn-primary")
    first?.focus()
  }

  backToCart() {
    if (this.hasCartTarget) this.cartTarget.dataset.step = "cart"
  }

  newSale() {
    this.backToCart()
    this.focusSearch(false)
  }

  async confirmClear() {
    const cart = this.cart()
    if (!cart || !cart.cart?.size) return
    const message = "Remove every item from this cart? The customer screen clears too."
    const confirmMethod = window.Turbo?.config?.forms?.confirm
    const ok = typeof confirmMethod === "function" ? await confirmMethod(message) : window.confirm(message)
    if (!ok) return
    cart.clear()
    this.backToCart()
    this.announce("Cart cleared.")
    this.focusSearch(false)
  }

  // --- Helpers ------------------------------------------------------------------------

  cart() {
    return this.application.getControllerForElementAndIdentifier(this.element, "pos-cart")
  }

  announce(message) {
    if (this.hasAnnounceTarget) this.announceTarget.textContent = message
  }

  label(item) {
    return [item.title, item.variant].filter(Boolean).join(" · ")
  }

  parse(raw) {
    if (!raw) return null
    try { return JSON.parse(raw) } catch (_) { return null }
  }
}
