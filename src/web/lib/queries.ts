import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import type {
  ControlState,
  CreatedDevice,
  Destination,
  DestinationInput,
  DeviceRow,
  IntegrationInfo,
  ListResponse,
  Prop,
  Recordings,
  SettingsInput,
  Show,
  ShowStatus,
  StudioInfo,
  UpdateShowInput,
} from "@shared/types";
import { api, errorMessage } from "./api";

export const keys = {
  info: ["info"] as const,
  devices: ["devices"] as const,
  shows: ["shows"] as const,
  show: (id: string) => ["shows", id] as const,
  status: (id: string) => ["shows", id, "status"] as const,
  destinations: ["destinations"] as const,
  props: ["props"] as const,
  recordings: ["recordings"] as const,
  integrations: ["integrations"] as const,
};

// ---------------------------------------------------------------- studio

export function useInfo() {
  return useQuery({ queryKey: keys.info, queryFn: () => api.get<StudioInfo>("/api/info"), staleTime: 30_000, retry: 1 });
}

export function useUpdateSettings() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: SettingsInput) => api.patch<StudioInfo>("/api/settings", input),
    onSuccess: (info) => qc.setQueryData(keys.info, info),
  });
}

// ---------------------------------------------------------------- phones

export function useDevices(opts?: { poll?: number }) {
  return useQuery({
    queryKey: keys.devices,
    queryFn: async () => (await api.get<ListResponse<DeviceRow>>("/api/devices")).items,
    refetchInterval: opts?.poll ?? 5_000,
  });
}

export function useCreateDevice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (name: string) => api.post<CreatedDevice>("/api/devices", { name }),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.devices }),
  });
}

export function useRenameDevice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, name }: { id: string; name: string }) => api.patch<DeviceRow>(`/api/devices/${id}`, { name }),
    onSuccess: () => {
      toast.success("Phone renamed");
      void qc.invalidateQueries({ queryKey: keys.devices });
    },
    onError: (e) => toast.error("Couldn't rename the phone", { description: errorMessage(e) }),
  });
}

export function useDeleteDevice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => api.del(`/api/devices/${id}`),
    onSuccess: () => {
      toast.success("Phone removed");
      void qc.invalidateQueries({ queryKey: keys.devices });
    },
    onError: (e) => toast.error("Couldn't remove the phone", { description: errorMessage(e) }),
  });
}

// ---------------------------------------------------------------- stream keys

export function useDestinations() {
  return useQuery({ queryKey: keys.destinations, queryFn: async () => (await api.get<ListResponse<Destination>>("/api/destinations")).items });
}

export function useCreateDestination() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: DestinationInput) => api.post<Destination>("/api/destinations", input),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.destinations }),
  });
}

export function useUpdateDestination() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...input }: Partial<DestinationInput> & { id: string }) => api.patch<Destination>(`/api/destinations/${id}`, input),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.destinations }),
  });
}

export function useDeleteDestination() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => api.del(`/api/destinations/${id}`),
    onSuccess: () => {
      toast.success("Stream key removed");
      void qc.invalidateQueries({ queryKey: keys.destinations });
    },
    onError: (e) => toast.error("Couldn't remove the stream key", { description: errorMessage(e) }),
  });
}

// ---------------------------------------------------------------- shows

export function useShows() {
  return useQuery({ queryKey: keys.shows, queryFn: async () => (await api.get<ListResponse<Show>>("/api/shows")).items, refetchInterval: 10_000 });
}

export function useShow(id: string | undefined) {
  return useQuery({ queryKey: keys.show(id ?? ""), queryFn: () => api.get<Show>(`/api/shows/${id}`), enabled: !!id, staleTime: Infinity, refetchOnWindowFocus: false });
}

export function useCreateShow() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (title: string) => api.post<Show>("/api/shows", { title }),
    onSuccess: (s) => {
      qc.setQueryData(keys.show(s.id), s);
      void qc.invalidateQueries({ queryKey: keys.shows, exact: true });
    },
  });
}

export function useUpdateShow(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: UpdateShowInput) => api.patch<Show>(`/api/shows/${id}`, input),
    onSuccess: (s) => {
      qc.setQueryData(keys.show(s.id), s);
      void qc.invalidateQueries({ queryKey: keys.shows, exact: true });
    },
    onError: (e) => toast.error("Couldn't save the show", { description: errorMessage(e) }),
  });
}

export function useDeleteShow() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => api.del(`/api/shows/${id}`),
    onSuccess: () => {
      toast.success("Show deleted");
      void qc.invalidateQueries({ queryKey: keys.shows, exact: true });
    },
    onError: (e) => toast.error("Couldn't delete the show", { description: errorMessage(e) }),
  });
}

/** The show's live status: polled every 2 s while it's live (or `fast`), every 15 s otherwise. */
export function useShowStatus(id: string, fast = false) {
  return useQuery({
    queryKey: keys.status(id),
    queryFn: () => api.get<ShowStatus>(`/api/shows/${id}/status`),
    refetchInterval: (q) => (fast || q.state.data?.state === "LIVE" ? 2_000 : 15_000),
  });
}

export function useStartShow(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => api.post<ShowStatus>(`/api/shows/${id}/start`),
    onSuccess: (st) => {
      qc.setQueryData(keys.status(id), st);
      void qc.invalidateQueries({ queryKey: keys.shows, exact: true });
    },
    onError: (e) => toast.error("Couldn't start the show", { description: errorMessage(e) }),
  });
}

export function useStopShow(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => api.post<ShowStatus>(`/api/shows/${id}/stop`),
    onSuccess: (st) => {
      if (st) qc.setQueryData(keys.status(id), st);
      void qc.invalidateQueries({ queryKey: keys.shows, exact: true });
      void qc.invalidateQueries({ queryKey: keys.recordings });
    },
    onError: (e) => toast.error("Couldn't end the show", { description: errorMessage(e) }),
  });
}

/** Mirror a take to the renderer (the caller decides whether a failure is worth a toast). */
export function useUpdateControl(id: string) {
  return useMutation({ mutationFn: (input: { programId: string | null; takeSeq: number }) => api.patch<{ version: number }>(`/api/shows/${id}/control`, input) });
}

/** The control state right now (since=-1 answers at once). */
export function fetchControl(id: string, since = -1, signal?: AbortSignal) {
  return api.get<ControlState>(`/api/shows/${id}/control?since=${since}`, { signal });
}

// ---------------------------------------------------------------- props

export function useProps() {
  return useQuery({ queryKey: keys.props, queryFn: async () => (await api.get<ListResponse<Prop>>("/api/props")).items });
}

export function useUploadProp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (file: File) => {
      const form = new FormData();
      form.append("name", file.name.replace(/\.[^.]+$/, "").slice(0, 60) || "Prop");
      form.append("file", file);
      return api.post<Prop>("/api/props", form);
    },
    onSuccess: (p) => {
      toast.success(p.kind === "video" ? "Video added" : "Image added", { description: "Use it in any scene." });
      void qc.invalidateQueries({ queryKey: keys.props });
    },
    onError: (e) => toast.error("Couldn't upload the file", { description: errorMessage(e) }),
  });
}

export function useDeleteProp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => api.del(`/api/props/${id}`),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.props }),
    onError: (e) => toast.error("Couldn't remove the file", { description: errorMessage(e) }),
  });
}

// ---------------------------------------------------------------- recordings

export function useRecordings() {
  return useQuery({ queryKey: keys.recordings, queryFn: () => api.get<Recordings>("/api/recordings"), refetchInterval: 10_000 });
}

export function useDeleteRecording() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (file: string) => api.del(`/api/recordings/${encodeURIComponent(file)}`),
    onSuccess: () => {
      toast.success("Recording deleted");
      void qc.invalidateQueries({ queryKey: keys.recordings });
    },
    onError: (e) => toast.error("Couldn't delete the recording", { description: errorMessage(e) }),
  });
}

// ---------------------------------------------------------------- integrations

export function useIntegrations() {
  return useQuery({
    queryKey: keys.integrations,
    queryFn: async () => (await api.get<ListResponse<IntegrationInfo>>("/api/integrations")).items,
    staleTime: 30_000,
    retry: false,
  });
}
