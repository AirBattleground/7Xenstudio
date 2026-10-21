/**
 * The generic shape of an integration's web UI (extensions). Core pages only know this interface and reach
 * integrations through ./registry.tsx — never by importing an integration folder directly.
 */
import type { ComponentType } from "react";
import type { IntegrationInfo, Show, ShowLink } from "@shared/types";

export interface ConsoleIntegrationProps {
  /** this integration's server-side state (connected, account) */
  info: IntegrationInfo;
  show: Show;
  /** the show's current link (may belong to another integration, or be null) */
  link: ShowLink | null;
  /** change (and save) the show's link */
  setLink: (link: ShowLink | null) => void;
  /** the show is on air: outputs and the linked event can't change */
  live: boolean;
}

export interface ProgramActionProps extends ConsoleIntegrationProps {
  /** a 1920×1080 PNG of the program without overlays */
  snapshot: () => Promise<Blob>;
}

export interface WebIntegration {
  /** matches IntegrationInfo.id from GET /api/integrations */
  id: string;
  /** Settings → Connections: connect / disconnect */
  ConnectPanel: ComponentType<{ info: IntegrationInfo }>;
  /** console top bar: link the show to one of the integration's events */
  EventPicker?: ComponentType<ConsoleIntegrationProps>;
  /** console Outputs panel: extra outputs (switches) */
  OutputsGroup?: ComponentType<ConsoleIntegrationProps>;
  /** under the program monitor (e.g. capture buttons) */
  ProgramActions?: ComponentType<ProgramActionProps>;
}
