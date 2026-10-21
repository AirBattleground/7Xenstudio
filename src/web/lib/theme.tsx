import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";

export type Theme = "light" | "dark" | "system";
const KEY = "7xen-studio.theme";

function readSaved(): Theme {
  try {
    const v = window.localStorage.getItem(KEY);
    return v === "light" || v === "dark" || v === "system" ? v : "system";
  } catch {
    return "system";
  }
}
function save(t: Theme) {
  try {
    window.localStorage.setItem(KEY, t);
  } catch {
    /* private mode / blocked storage: the choice lasts for this visit only */
  }
}
const systemDark = () => typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches;

interface ThemeCtx {
  theme: Theme;
  resolvedTheme: "light" | "dark";
  setTheme: (t: Theme) => void;
}
const Ctx = createContext<ThemeCtx>({ theme: "system", resolvedTheme: "dark", setTheme: () => undefined });

/** Light / dark / system, saved in this browser. Toggles the `dark` class on <html>. */
export function ThemeProvider({ children, force }: { children: ReactNode; force?: "light" | "dark" }) {
  const [theme, setThemeState] = useState<Theme>(readSaved);
  const [sysDark, setSysDark] = useState(systemDark);
  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const on = () => setSysDark(mq.matches);
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, []);
  const resolvedTheme = force ?? (theme === "system" ? (sysDark ? "dark" : "light") : theme);
  useEffect(() => {
    const root = document.documentElement;
    root.classList.add("theme-transition");
    root.classList.toggle("dark", resolvedTheme === "dark");
    const t = window.setTimeout(() => root.classList.remove("theme-transition"), 450);
    return () => window.clearTimeout(t);
  }, [resolvedTheme]);
  const setTheme = useCallback((t: Theme) => {
    setThemeState(t);
    save(t);
  }, []);
  return <Ctx.Provider value={{ theme, resolvedTheme, setTheme }}>{children}</Ctx.Provider>;
}

export const useTheme = () => useContext(Ctx);
