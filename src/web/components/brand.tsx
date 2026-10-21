import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

/** The 7XEN Studio mark: a rounded tile with an X (pure SVG, follows the theme's primary colour). */
export function LogoMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" aria-hidden className={cn("size-8 drop-shadow-[0_4px_14px_var(--glow)]", className)}>
      <rect width="32" height="32" rx="8" className="fill-primary" />
      <path d="M10 10l12 12M22 10L10 22" strokeWidth="4" strokeLinecap="round" className="stroke-primary-foreground" />
    </svg>
  );
}

export function Logo({ className }: { className?: string }) {
  return (
    <span className={cn("inline-flex items-center gap-2", className)}>
      <LogoMark />
      <span className="font-display text-xl leading-none font-bold tracking-wide">
        7XEN <span className="text-primary">Studio</span>
      </span>
    </span>
  );
}

export function PageHeader({ title, description, actions }: { title: ReactNode; description?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-6 flex animate-rise flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div className="min-w-0">
        <h1 className="font-display text-3xl font-bold sm:text-4xl">{title}</h1>
        {description && <p className="mt-1.5 max-w-2xl text-sm text-muted-foreground sm:text-base">{description}</p>}
      </div>
      {actions && <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div>}
    </div>
  );
}

export function EmptyState({ icon, title, description, action, className }: { icon?: ReactNode; title: ReactNode; description?: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <div className={cn("flex animate-rise flex-col items-center justify-center rounded-xl border border-dashed px-6 py-14 text-center", className)}>
      {icon && <div className="mb-4 rounded-2xl bg-primary/10 p-4 text-primary [&_svg]:size-7">{icon}</div>}
      <h3 className="font-display text-xl font-bold">{title}</h3>
      {description && <p className="mt-1.5 max-w-sm text-sm text-muted-foreground">{description}</p>}
      {action && <div className="mt-5">{action}</div>}
    </div>
  );
}

export function FullPageLoader({ label = "Loading…" }: { label?: string }) {
  return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3 text-muted-foreground">
      <span className="size-10 animate-spin rounded-full border-[3px] border-primary/20 border-t-primary" />
      <span className="text-sm">{label}</span>
    </div>
  );
}

/** "Couldn't load" card with a retry button. */
export function QueryError({ title, message, onRetry }: { title: string; message?: string; onRetry?: () => void }) {
  return (
    <div className="rounded-xl border border-destructive/40 bg-destructive/10 p-5">
      <p className="font-semibold text-destructive">{title}</p>
      {message && <p className="mt-1 text-sm text-muted-foreground">{message}</p>}
      {onRetry && (
        <button type="button" onClick={onRetry} className="mt-3 text-sm font-semibold text-primary underline-offset-4 hover:underline">
          Try again
        </button>
      )}
    </div>
  );
}

/** Small coloured status chip (theme tokens only). */
export function Chip({ tone = "muted", children, className, title }: { tone?: "muted" | "success" | "warning" | "danger" | "primary" | "live"; children: ReactNode; className?: string; title?: string }) {
  const tones = {
    muted: "bg-muted text-muted-foreground",
    success: "bg-success/15 text-success",
    warning: "bg-warning/20 text-warning-foreground dark:text-warning",
    danger: "bg-destructive/15 text-destructive",
    primary: "bg-primary/15 text-primary",
    live: "bg-destructive text-white",
  } as const;
  return (
    <span title={title} className={cn("inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-semibold whitespace-nowrap", tones[tone], className)}>
      {children}
    </span>
  );
}
