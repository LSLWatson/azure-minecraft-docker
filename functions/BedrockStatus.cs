using System;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace EW.Minecraft.Function
{
    public sealed class BedrockStatus
    {
        public string Version { get; }
        public int Players { get; }
        public int MaxPlayers { get; }

        private BedrockStatus(string version, int players, int maxPlayers)
        {
            Version = version;
            Players = players;
            MaxPlayers = maxPlayers;
        }

        public static async Task<BedrockStatus> GetAsync(
            HttpClient client, string host, int port, CancellationToken cancellationToken = default)
        {
            if (port < 1 || port > 65535)
            {
                throw new ArgumentOutOfRangeException(nameof(port));
            }

            var uri = new UriBuilder(Uri.UriSchemeHttp, host, port, "/v1/join").Uri;
            using var response = await client.GetAsync(uri, cancellationToken);
            response.EnsureSuccessStatusCode();
            var content = await response.Content.ReadAsStringAsync(cancellationToken);

            try
            {
                using var document = JsonDocument.Parse(content);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object ||
                    !root.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String ||
                    !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.String ||
                    string.IsNullOrWhiteSpace(version.GetString()) ||
                    !TryGetInteger(root, "protocol", out var protocol) || protocol <= 0 ||
                    !TryGetInteger(root, "players", out var players) || players < 0 ||
                    !TryGetInteger(root, "maxPlayers", out var maxPlayers) || maxPlayers < 1 || players > maxPlayers)
                {
                    throw new InvalidDataException("Response is not valid Bedrock NetherNet server status.");
                }

                return new BedrockStatus(version.GetString(), players, maxPlayers);
            }
            catch (JsonException ex)
            {
                throw new InvalidDataException("Bedrock returned invalid JSON.", ex);
            }
        }

        private static bool TryGetInteger(JsonElement root, string name, out int value)
        {
            value = 0;
            return root.TryGetProperty(name, out var element) &&
                element.ValueKind == JsonValueKind.Number && element.TryGetInt32(out value);
        }
    }
}
