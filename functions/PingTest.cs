using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.Azure.WebJobs;
using Microsoft.Extensions.Logging;

namespace EW.Minecraft.Function
{
    public class PingTest
    {
        private static readonly HttpClient Client = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        private readonly TelemetryClient telemetryClient;

        public PingTest(TelemetryConfiguration telemetryConfiguration)
        {
            telemetryClient = new TelemetryClient(telemetryConfiguration);
        }

        [FunctionName("PingTest")]
        public async Task Run(
            [TimerTrigger("0 */5 * * * *", RunOnStartup = false, UseMonitor = true)] TimerInfo timer,
            ILogger log)
        {
            if (timer.IsPastDue)
            {
                log.LogInformation("Timer is running late!");
            }

            var stopwatch = Stopwatch.StartNew();
            var properties = new Dictionary<string, string>
            {
                ["Connected"] = "False",
                ["Transport"] = "NetherNet"
            };

            try
            {
                var host = GetVariableValue("MINECRAFT_FQDN");
                var port = int.Parse(GetVariableValue("MINECRAFT_PORT"));
                var status = await BedrockStatus.GetAsync(Client, host, port);
                properties["Connected"] = "True";
                properties["Version"] = status.Version;
                properties["Players"] = status.Players.ToString();
                properties["MaxPlayers"] = status.MaxPlayers.ToString();
                log.LogInformation("Bedrock {Version} responded in {Elapsed} ms ({Players}/{MaxPlayers} players).",
                    status.Version, stopwatch.ElapsedMilliseconds, status.Players, status.MaxPlayers);
            }
            catch (HttpRequestException ex)
            {
                log.LogError(ex, "Bedrock signaling endpoint is inaccessible.");
            }
            catch (TaskCanceledException ex)
            {
                log.LogError(ex, "Bedrock signaling request timed out.");
            }
            catch (InvalidDataException ex)
            {
                log.LogError(ex, "Bedrock signaling endpoint returned invalid status.");
            }
            finally
            {
                telemetryClient.TrackTrace("TestResult",
                    properties["Connected"] == "True" ? SeverityLevel.Information : SeverityLevel.Warning,
                    properties);
            }
        }

        private static string GetVariableValue(string variableName)
        {
            var value = Environment.GetEnvironmentVariable(variableName);
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException($"Environment variable {variableName} is not set.");
            }

            return value;
        }
    }
}
