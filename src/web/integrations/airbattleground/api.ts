import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { IntegrationInfo, IntegrationOutput, ListResponse, StudioEvent } from "@shared/types";
import { api } from "@/lib/api";
import { keys } from "@/lib/queries";

export const ID = "airbattleground";
const base = `/api/integrations/${ID}`;

export function useConnect() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (link: string) => api.post<IntegrationInfo>(`${base}/connect`, { link }),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.integrations }),
  });
}

export function useDisconnect() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => api.del(base),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.integrations }),
  });
}

export function useEvents(enabled: boolean) {
  return useQuery({
    queryKey: [...keys.integrations, ID, "events"],
    queryFn: async () => (await api.get<ListResponse<StudioEvent>>(`${base}/events`)).items,
    enabled,
    staleTime: 30_000,
    retry: false,
  });
}

export function useOutputs(enabled: boolean) {
  return useQuery({
    queryKey: [...keys.integrations, ID, "outputs"],
    queryFn: async () => (await api.get<ListResponse<IntegrationOutput>>(`${base}/outputs`)).items,
    enabled,
    staleTime: 60_000,
    retry: false,
  });
}

export function captureToEvent(eventId: string, png: Blob, kind: "SLOT_LIST" | "RESULTS") {
  const form = new FormData();
  form.append("kind", kind);
  form.append("file", new File([png], `studio-${kind.toLowerCase()}-${Date.now()}.png`, { type: "image/png" }));
  return api.post<{ ok: true }>(`${base}/events/${encodeURIComponent(eventId)}/capture`, form);
}
