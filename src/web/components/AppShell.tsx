import { NavLink, Outlet } from "react-router-dom";
import { Clapperboard, Film, Settings, Smartphone } from "lucide-react";
import { cn } from "@/lib/utils";
import { useInfo } from "@/lib/queries";
import { Logo } from "./brand";
import { ThemeToggle } from "./ThemeToggle";

const NAV = [
  { to: "/", label: "Shows", icon: Clapperboard, end: true },
  { to: "/phones", label: "Phones", icon: Smartphone, end: false },
  { to: "/recordings", label: "Recordings", icon: Film, end: false },
  { to: "/settings", label: "Settings", icon: Settings, end: false },
];

/** Top bar (logo, nav, theme) + page container. The console uses `wide` for a full-width layout. */
export function AppShell() {
  const info = useInfo();
  return (
    <div className="flex min-h-dvh flex-col bg-background">
      <header className="sticky top-0 z-40 border-b bg-card/80 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-[1800px] items-center gap-3 px-4">
          <NavLink to="/" className="shrink-0" aria-label="7XEN Studio home">
            <Logo className="hidden sm:inline-flex" />
            <Logo className="sm:hidden [&>span:last-child]:hidden" />
          </NavLink>
          {info.data?.name && <span className="hidden truncate text-sm text-muted-foreground lg:inline">· {info.data.name}</span>}
          <nav className="ml-auto flex items-center gap-1 overflow-x-auto">
            {NAV.map((n) => (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) =>
                  cn(
                    "flex items-center gap-1.5 rounded-md px-2.5 py-2 text-sm font-semibold whitespace-nowrap transition-colors",
                    isActive ? "bg-primary/15 text-primary" : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
                  )
                }
              >
                <n.icon className="size-4" />
                <span className="hidden sm:inline">{n.label}</span>
              </NavLink>
            ))}
          </nav>
          <ThemeToggle />
        </div>
      </header>
      <main className="flex-1">
        <Outlet />
      </main>
    </div>
  );
}

/** Page container for the normal (non-console) pages. */
export function PageContainer({ children }: { children: React.ReactNode }) {
  return <div className="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6 sm:py-8">{children}</div>;
}
