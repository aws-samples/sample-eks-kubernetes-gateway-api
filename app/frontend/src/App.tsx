import { useCallback, useEffect, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import ProductGrid from "./components/ProductGrid";
import CartView from "./components/CartView";
import PaymentConfirmationView from "./components/PaymentConfirmation";
import NoConnectivityMessage from "./components/NoConnectivityMessage";
import ArchitectureDiagram from "./components/ArchitectureDiagram";
import { fetchHealth, fetchInventory, fetchCart, processPayment, addToCart, clearCart, ApiError } from "./api";
import type { Product, CartItem, LatticeHeaders, PaymentConfirmation } from "./types";

const HEALTH_POLL_INTERVAL = 5_000;
type View = "shop" | "cart" | "confirmation";

function App() {
  const [cartReachable, setCartReachable] = useState(false);
  const [paymentsReachable, setPaymentsReachable] = useState(false);
  const [inventoryReachable, setInventoryReachable] = useState(false);

  const [products, setProducts] = useState<Product[]>([]);
  const [inventoryHeaders, setInventoryHeaders] = useState<LatticeHeaders | null>(null);
  const [cartItems, setCartItems] = useState<CartItem[]>([]);
  const [cartTotal, setCartTotal] = useState(0);
  const [cartHeaders, setCartHeaders] = useState<LatticeHeaders | null>(null);
  const [cartCount, setCartCount] = useState(0);
  const [paymentResult, setPaymentResult] = useState<PaymentConfirmation | null>(null);

  const [view, setView] = useState<View>("shop");
  const [adding, setAdding] = useState<string | null>(null);
  const [paying, setPaying] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [activeService, setActiveService] = useState<string | null>(null);

  const checkHealth = useCallback(async () => {
    try {
      const h = await fetchHealth();
      setCartReachable(h.cart_service === "reachable");
      setPaymentsReachable(h.payments_service === "reachable");
      setInventoryReachable(h.inventory_service === "reachable");
    } catch {
      setCartReachable(false);
      setPaymentsReachable(false);
      setInventoryReachable(false);
    }
  }, []);

  const loadInventory = useCallback(async () => {
    try {
      setActiveService("inventory");
      const res = await fetchInventory();
      setProducts(res.data.products);
      setInventoryHeaders(res.lattice_headers);
    } catch { /* silent */ }
    setActiveService(null);
  }, []);

  const loadCart = useCallback(async () => {
    try {
      setActiveService("cart");
      const res = await fetchCart();
      setCartItems(res.data.items);
      setCartTotal(res.data.total);
      setCartCount(res.data.count);
      setCartHeaders(res.lattice_headers);
    } catch { /* silent */ }
    setActiveService(null);
  }, []);

  useEffect(() => {
    checkHealth();
    const id = setInterval(checkHealth, HEALTH_POLL_INTERVAL);
    return () => clearInterval(id);
  }, [checkHealth]);

  useEffect(() => {
    if (inventoryReachable && products.length === 0) loadInventory();
  }, [inventoryReachable, products.length, loadInventory]);

  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(null), 4000);
    return () => clearTimeout(id);
  }, [toast]);

  const handleAddToCart = useCallback(async (product: Product) => {
    if (adding) return;
    setAdding(product.sku);
    try {
      const res = await addToCart(product.sku, product.name, product.price);
      setCartCount(res.count);
    } catch (err) {
      setToast(err instanceof ApiError ? err.message : "Failed to add to cart");
    }
    setAdding(null);
  }, [adding]);

  const handleViewCart = useCallback(async () => {
    setView("cart");
    await loadCart();
  }, [loadCart]);

  const handleBackToShop = useCallback(() => {
    setView("shop");
    setPaymentResult(null);
  }, []);

  const handlePay = useCallback(async () => {
    setPaying(true);
    setActiveService("payments");
    try {
      const result = await processPayment(cartItems, cartTotal);
      await clearCart();
      setPaymentResult(result);
      setCartItems([]);
      setCartTotal(0);
      setCartCount(0);
      setView("confirmation");
    } catch (err) {
      setToast(err instanceof ApiError ? err.message : "Payment failed");
    }
    setPaying(false);
    setActiveService(null);
  }, [cartItems, cartTotal]);

  const handleClearCart = useCallback(async () => {
    try {
      await clearCart();
      setCartItems([]);
      setCartTotal(0);
      setCartCount(0);
    } catch { /* silent */ }
  }, []);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
      <header className="flex items-center justify-between px-6 py-3 border-b border-slate-800">
        <button onClick={handleBackToShop} className="text-lg font-semibold tracking-tight hover:text-slate-300 transition-colors">
          🦄 Unicorn Store
        </button>
        <div className="flex items-center gap-3">
          {view !== "shop" && (
            <button onClick={handleBackToShop} className="text-xs text-slate-400 hover:text-slate-200 transition-colors">
              ← Shop
            </button>
          )}
          <button onClick={handleViewCart} className="relative flex items-center gap-2 px-3 py-1.5 rounded-lg border border-slate-700 hover:bg-slate-800 transition-colors">
            <span>🛒</span>
            <span className="text-sm text-slate-300">Cart</span>
            {cartCount > 0 && (
              <span className="absolute -top-2 -right-2 bg-emerald-500 text-white text-[10px] font-bold w-5 h-5 rounded-full flex items-center justify-center">
                {cartCount}
              </span>
            )}
          </button>
        </div>
      </header>

      <main className="flex flex-1 overflow-hidden">
        <section className="w-1/2 p-4 flex flex-col overflow-hidden border-r border-slate-800">
          {view === "shop" ? (
            !inventoryReachable ? (
              <NoConnectivityMessage service="Inventory" />
            ) : (
              <ProductGrid products={products} latticeHeaders={inventoryHeaders} onAddToCart={handleAddToCart} adding={adding} />
            )
          ) : view === "cart" ? (
            !cartReachable ? (
              <NoConnectivityMessage service="Cart" />
            ) : (
              <CartView items={cartItems} total={cartTotal} latticeHeaders={cartHeaders} onPay={handlePay} onClear={handleClearCart} paying={paying} />
            )
          ) : (
            paymentResult && (
              <PaymentConfirmationView payment={paymentResult} onBackToShop={handleBackToShop} />
            )
          )}
        </section>

        <section className="w-1/2 p-4 overflow-hidden">
          <ArchitectureDiagram
            cartReachable={cartReachable}
            paymentsReachable={paymentsReachable}
            inventoryReachable={inventoryReachable}
            activeService={activeService}
          />
        </section>
      </main>

      <AnimatePresence>
        {toast && (
          <motion.div initial={{ opacity: 0, y: 40 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 40 }} transition={{ duration: 0.3 }}
            className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50" role="alert">
            <div className="rounded-lg border border-slate-600 bg-slate-900/95 px-5 py-3 text-sm text-slate-200 shadow-lg backdrop-blur-sm">
              {toast}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

export default App;
