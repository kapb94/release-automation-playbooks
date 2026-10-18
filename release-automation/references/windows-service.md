# 02. Automatización para Servicios de Windows (.NET Worker Services)

Guía completa y plantillas listas para copiar y usar en servicios en segundo plano sobre Windows Server (`.NET 6 / 8 / 9 Worker Services`, integraciones SAP Business One Service Layer, demonios de facturación electrónica, sincronizadores de base de datos).

---

## 📦 Archivos Incluidos en Esta Categoría

1. **[`templates/DeploymentInfo.cs`](./templates/DeploymentInfo.cs):** Clase helper en C# que lee `release-manifest.json` (o los atributos MSBuild del `.exe`) para exponer el `ReleaseTag`, canal (`stable`/`rc`), `DeploymentId` y `CommitSha`.
2. **[`templates/github-workflow-release.yml`](./templates/github-workflow-release.yml):** Workflow de GitHub Actions que ejecuta pruebas unitarias, compila para `win-x64`, remueve archivos de configuración local (`config.json`), genera `release-manifest.json` y publica el `.zip` en GitHub Releases.
3. **[`templates/Manage-WindowsService.ps1`](./templates/Manage-WindowsService.ps1):** Script PowerShell todo-en-uno para el servidor Windows con:
   - **Autodetección del nombre del servicio** mediante `Win32_Service` buscando el ejecutable en la carpeta actual.
   - **`status`**: Muestra estado del servicio, versión instalada, canal suscrito y compara contra GitHub Releases.
   - **`update`**: Crea backup `.zip`, detiene el servicio, actualiza binarios respetando `config.json`, registra en `deployments-history.log` y arranca el servicio.
   - **`register-autoupdate` / `set-channel` / `auto-update`**: Crea una Tarea Programada de Windows (`SYSTEM`) que vigila automáticamente el canal `stable` o `rc`.
   - **`install-service`** y **`rollback`**.

---

## 🛠️ Paso a Paso para Integrarlo en un Proyecto .NET

### Paso 1: Configurar el `.csproj` del Servicio
Agrega las propiedades de versionamiento en el `<PropertyGroup>` principal de tu proyecto `.csproj`:

```xml
<PropertyGroup>
  <TargetFramework>net6.0</TargetFramework>
  <RollForward>LatestMajor</RollForward>
  <Version>1.0.0</Version>
  <InformationalVersion Condition="'$(ReleaseTag)' != ''">$(ReleaseTag)</InformationalVersion>
  <IncludeSourceRevisionInInformationalVersion>true</IncludeSourceRevisionInInformationalVersion>
</PropertyGroup>
```

### Paso 2: Soportar `--version` y Log de Inicio en `Program.cs`
En el método `Main(string[] args)` de tu `Program.cs`, agrega la verificación de `--version` y el registro al iniciar el servicio:

```csharp
public static void Main(string[] args)
{
    if (args != null && args.Any(a => a.Equals("--version", StringComparison.OrdinalIgnoreCase) || a.Equals("-v", StringComparison.OrdinalIgnoreCase)))
    {
        var release = DeploymentInfo.GetCurrentRelease();
        Console.WriteLine("=======================================================");
        Console.WriteLine($" Release Tag     : {release.ReleaseTag}");
        Console.WriteLine($" Canal (Channel) : {(release.Channel == "rc" ? "RC (Pre-release / Pruebas)" : "Stable (Produccion)")}");
        Console.WriteLine($" Deployment ID   : {release.DeploymentId}");
        Console.WriteLine($" Commit SHA      : {release.CommitSha}");
        Console.WriteLine($" Publicado (UTC) : {release.PublishedAtUtc}");
        Console.WriteLine($" Instalado Local : {release.InstalledAtLocal}");
        Console.WriteLine("=======================================================");
        return;
    }

    CreateHostBuilder(args).Build().Run();
}
```

### Paso 3: Comandos en el Servidor Windows

```powershell
# 1. Configurar el token de lectura de GitHub a nivel de máquina (una sola vez):
[Environment]::SetEnvironmentVariable("GITHUB_TOKEN", "github_pat_TU_TOKEN", "Machine")

# 2. Ver qué versión y canal corre actualmente el servidor:
.\Manage-WindowsService.ps1 -Action status

# 3. Actualizar manualmente al último Release Candidate (rc) o Stable:
.\Manage-WindowsService.ps1 -Action update -Channel rc
.\Manage-WindowsService.ps1 -Action update -Channel stable

# 4. Si es una carpeta nueva donde aún no existe el Servicio de Windows:
.\Manage-WindowsService.ps1 -Action install-service -ServiceName "MiServicioWindows"

# 5. Activar la auto-actualización por Tarea Programada de Windows:
#    En Servidor QA (vigila RC cada 10 min):
.\Manage-WindowsService.ps1 -Action register-autoupdate -Channel rc -IntervalMinutes 10
#    En Servidor Producción (vigila solo Stable cada 15 min):
.\Manage-WindowsService.ps1 -Action register-autoupdate -Channel stable -IntervalMinutes 15

# 6. Cambiar de canal en vivo sin recrear la tarea programada:
.\Manage-WindowsService.ps1 -Action set-channel -Channel rc
.\Manage-WindowsService.ps1 -Action set-channel -Channel stable

# 7. Hacer Rollback inmediato a la versión anterior:
.\Manage-WindowsService.ps1 -Action rollback
```
