/**
 * The ONLY place core UI touches integrations. Each entry is an integration's web module (its own folder under
 * src/web/integrations/<id>/). Delete the folder and its line here, and the app still builds and works.
 */
import type { WebIntegration } from "./types";
import { integration as airbattleground } from "./airbattleground";

export const INTEGRATIONS: readonly WebIntegration[] = [airbattleground];

export function integrationUi(id: string): WebIntegration | undefined {
  return INTEGRATIONS.find((i) => i.id === id);
}

export type { ConsoleIntegrationProps, ProgramActionProps, WebIntegration } from "./types";
