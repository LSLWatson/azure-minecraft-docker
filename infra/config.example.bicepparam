using './main.bicep'

param environment = 'dev'
param minecraftUsers = [
  // 'Your Gamertag:2535412345678901'
]
param minecraftOps = []
param minecraftConfig = [
  {
    name: 'primary'
    maxPlayers: 4
    environmentVariables: {
      EULA: 'TRUE'
      VERSION: 'LATEST'
      SERVER_NAME: 'Our Bedrock server'
      LEVEL_NAME: 'Bedrock level'
      GAMEMODE: 'creative'
    }
  }
]
param enableBackup = false
param enableAutoStartStop = false
