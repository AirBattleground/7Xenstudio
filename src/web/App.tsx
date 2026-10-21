import { useEffect, useState } from "react";
import { BrowserRouter, Route, Routes, useLocation } from "react-router-dom";
import { QueryClient, QueryClientProvider, useQueryClient } from "@tanstack/react-query";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { AppShell, PageContainer } from "@/components/AppShell";
import { FullPageLoader, QueryError } from "@/components/brand";
import { PinScreen } from "@/components/PinScreen";
import { ApiError, errorMessage, setPinRequiredHandler } from "@/lib/api";
import { keys, useInfo } from "@/lib/queries";
import { ThemeProvider } from "@/lib/theme";
import ShowsPage from "@/pages/ShowsPage";
import ConsolePage from "@/pages/ConsolePage";
import PhonesPage from "@/pages/PhonesPage";
import RecordingsPage from "@/pages/RecordingsPage";
import SettingsPage from "@/pages/SettingsPage";
import RenderPage from "@/pages/RenderPage";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: (n, e) => !(e instanceof ApiError && e.status >= 400 && e.status < 500) && n < 2,
      refetchOnWindowFocus: true,
    },
  },
});

export function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <Root />
      </BrowserRouter>
    </QueryClientProvider>
  );
}

function Root() {
  const { pathname } = useLocation();
  // the render page runs headless on this PC: no chrome, no PIN screen (it carries its own token)
  if (pathname.startsWith("/render/")) {
    return (
      <ThemeProvider force="dark">
        <Routes>
          <Route path="/render/:showId" element={<RenderPage />} />
        </Routes>
      </ThemeProvider>
    );
  }
  return (
    <ThemeProvider>
      <TooltipProvider delayDuration={300}>
        <Gate />
        <Toaster richColors position="bottom-right" />
      </TooltipProvider>
    </ThemeProvider>
  );
}

/** Ask for the PIN when the studio has one and this browser hasn't entered it. */
function Gate() {
  const qc = useQueryClient();
  const info = useInfo();
  const [locked, setLocked] = useState(false);
  useEffect(() => {
    setPinRequiredHandler(() => setLocked(true));
    return () => setPinRequiredHandler(null);
  }, []);
  if (info.isPending) return <FullPageLoader label="Opening the studio…" />;
  if (info.isError)
    return (
      <div className="mx-auto max-w-lg p-6">
        <QueryError title="Can't reach 7XEN Studio" message={errorMessage(info.error)} onRetry={() => void info.refetch()} />
      </div>
    );
  if (locked || (info.data.pinRequired && !info.data.authed))
    return (
      <PinScreen
        studioName={info.data.name}
        onUnlocked={() => {
          setLocked(false);
          qc.setQueryData(keys.info, { ...info.data, authed: true });
          void qc.invalidateQueries();
        }}
      />
    );
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<PageContainer><ShowsPage /></PageContainer>} />
        <Route path="/shows/:showId" element={<ConsolePage />} />
        <Route path="/phones" element={<PageContainer><PhonesPage /></PageContainer>} />
        <Route path="/recordings" element={<PageContainer><RecordingsPage /></PageContainer>} />
        <Route path="/settings" element={<PageContainer><SettingsPage /></PageContainer>} />
        <Route path="*" element={<PageContainer><QueryError title="Page not found" message="Use the menu at the top to find your way." /></PageContainer>} />
      </Route>
    </Routes>
  );
}
