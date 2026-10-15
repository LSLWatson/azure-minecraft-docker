@export()
@sealed()
type BedrockEnvironment = {
  EULA: string?
  VERSION: string?
  SERVER_NAME: string?
  GAMEMODE: ('survival' | 'creative' | 'adventure')?
  DIFFICULTY: ('peaceful' | 'easy' | 'normal' | 'hard')?
  ALLOW_CHEATS: string?
  ONLINE_MODE: string?
  LEVEL_NAME: string?
  LEVEL_SEED: string?
  LEVEL_TYPE: string?
  VIEW_DISTANCE: string?
  TICK_DISTANCE: string?
  PLAYER_IDLE_TIMEOUT: string?
  MAX_THREADS: string?
  DEFAULT_PLAYER_PERMISSION_LEVEL: string?
  TEXTUREPACK_REQUIRED: string?
  CONTENT_LOG_FILE_ENABLED: string?
  CONTENT_LOG_CONSOLE_OUTPUT_ENABLED: string?
  CHAT_RESTRICTION: string?
  MC_PACK: string?
  FORCE_WORLD_COPY: string?
  FORCE_PACK_COPY: string?
}

@export()
@sealed()
type MinecraftInstance = {
  @minLength(1)
  @maxLength(32)
  name: string
  containerName: string?
  dnsNameLabel: string?
  dataShareName: string?
  createDataShare: bool?
  functionName: string?
  functionStorageAccountName: string?
  createFunctionStorageAccount: bool?
  adoptFunction: bool?
  image: string?
  imageTag: string?
  @minValue(1)
  @maxValue(4)
  maxPlayers: int?
  @minValue(1)
  @maxValue(65535)
  serverPort: int?
  @minValue(1)
  @maxValue(65535)
  udpPortStart: int?
  allowListEnabled: bool?
  allowOpsOnly: bool?
  environmentVariables: BedrockEnvironment?
  startTime: string?
  startTimeWeekend: string?
  stopTime: string?
  stopTimeWeekend: string?
  vanityHostnamePrefix: string?
}
