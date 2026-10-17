namespace TheOptimiser.Services;

// Short, plain-language notes: what each service does and the trade-off of changing its startup.
public static class ServiceInfo
{
    private static readonly Dictionary<string, string> Map = new(StringComparer.OrdinalIgnoreCase)
    {
        ["CscService"] =
            "Offline Files - caches files from network shares so they're available when you're disconnected. " +
            "Safe to turn off if you don't use Offline Files or network shares (frees a little memory). " +
            "Downside: offline sync of network files stops.",

        ["DiagTrack"] =
            "Connected User Experiences and Telemetry - sends diagnostic and usage data to Microsoft. " +
            "Disabling improves privacy and trims background activity, and is generally safe. " +
            "Downside: some feedback and enterprise diagnostic features stop reporting.",

        ["MapsBroker"] =
            "Downloaded Maps Manager - downloads and updates offline maps for the Maps app. " +
            "Turn off if you don't use offline maps (minor resource saving). " +
            "Downside: offline maps won't download or update.",

        ["SharedAccess"] =
            "Internet Connection Sharing (ICS) - shares your internet with other devices and powers Mobile Hotspot. " +
            "Turn off if you never share your connection or use Mobile Hotspot. " +
            "Downside: Mobile Hotspot and connection sharing stop working.",

        ["StorSvc"] =
            "Storage Service - handles storage settings, Storage Sense and parts of app installation. " +
            "Left on Manual (not disabled) so it starts only when needed. " +
            "Fully disabling it can break Microsoft Store installs and Storage settings, so Manual is the safe middle ground.",

        ["lfsvc"] =
            "Geolocation Service - provides your location to apps. " +
            "Turn off for privacy if you don't use location-aware apps. " +
            "Downside: Find My Device, weather/maps location and other location features stop working.",
    };

    public static string Describe(string name) => Map.TryGetValue(name, out var d) ? d
        : "Changes this service's startup type. Fewer always-on services can free memory and speed boot - reversible from Undo.";
}
