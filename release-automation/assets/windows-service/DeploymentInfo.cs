using Newtonsoft.Json;
using System;
using System.IO;
using System.Reflection;

namespace FE.Helpers
{
    public class ReleaseManifest
    {
        [JsonProperty("releaseTag")]
        public string ReleaseTag { get; set; }

        [JsonProperty("channel")]
        public string Channel { get; set; }

        [JsonProperty("deploymentId")]
        public string DeploymentId { get; set; }

        [JsonProperty("commitSha")]
        public string CommitSha { get; set; }

        [JsonProperty("publishedAtUtc")]
        public string PublishedAtUtc { get; set; }

        [JsonProperty("installedAtLocal")]
        public string InstalledAtLocal { get; set; }
    }

    public static class DeploymentInfo
    {
        private static ReleaseManifest _cachedManifest;

        public static ReleaseManifest GetCurrentRelease()
        {
            if (_cachedManifest != null)
                return _cachedManifest;

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string manifestPath = Path.Combine(baseDir, "release-manifest.json");

            if (File.Exists(manifestPath))
            {
                try
                {
                    string json = File.ReadAllText(manifestPath);
                    var manifest = JsonConvert.DeserializeObject<ReleaseManifest>(json);
                    if (manifest != null)
                    {
                        if (string.IsNullOrEmpty(manifest.Channel))
                        {
                            manifest.Channel = (manifest.ReleaseTag != null && manifest.ReleaseTag.Contains("-")) ? "rc" : "stable";
                        }
                        _cachedManifest = manifest;
                        return _cachedManifest;
                    }
                }
                catch
                {
                    // Fallback to assembly metadata if manifest cannot be read
                }
            }

            var assembly = Assembly.GetEntryAssembly() ?? Assembly.GetExecutingAssembly();
            string infoVersion = assembly
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                .InformationalVersion ?? assembly.GetName().Version?.ToString() ?? "v0.0.0-local";

            string tag = infoVersion;
            string commit = "local";

            if (infoVersion.Contains("+"))
            {
                var parts = infoVersion.Split('+', 2);
                tag = parts[0];
                commit = parts[1].Length > 7 ? parts[1].Substring(0, 7) : parts[1];
            }

            string normalizedTag = tag.StartsWith("v") ? tag : $"v{tag}";
            bool isPreRelease = normalizedTag.Contains("-");
            string prefix = isPreRelease ? "RC" : "LOCAL";

            _cachedManifest = new ReleaseManifest
            {
                ReleaseTag = normalizedTag,
                Channel = isPreRelease ? "rc" : "stable",
                DeploymentId = $"{prefix}-{normalizedTag}-{commit}",
                CommitSha = commit,
                PublishedAtUtc = File.GetLastWriteTimeUtc(assembly.Location).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                InstalledAtLocal = File.GetLastWriteTime(assembly.Location).ToString("yyyy-MM-dd HH:mm:ss")
            };

            return _cachedManifest;
        }

        public static string GetSummaryBanner()
        {
            var info = GetCurrentRelease();
            string channelBadge = string.Equals(info.Channel, "rc", StringComparison.OrdinalIgnoreCase) ? " [RC / PRE-RELEASE]" : " [STABLE]";
            return $"Release: {info.ReleaseTag}{channelBadge} | DeploymentID: {info.DeploymentId} | Commit: {info.CommitSha} | Publicado: {info.PublishedAtUtc}";
        }
    }
}
