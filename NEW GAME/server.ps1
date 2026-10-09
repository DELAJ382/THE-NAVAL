$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Mail;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

public sealed class OutlandPeer
{
    public string Id;
    public string Room;
    public string Name;
    public string Email;
    public string Mode;
    public string DropSite;
    public string Weapon = "rifle";
    public string Color = "#687d53";
    public int Team = -1;
    public double X;
    public double Z;
    public double Y;
    public double Yaw;
    public int Health = 100;
    public DateTime LastHit = DateTime.MinValue;
    public DateTime LastDamage = DateTime.MinValue;
    public WebSocket Socket;
    public readonly SemaphoreSlim SendGate = new SemaphoreSlim(1, 1);
}

public sealed class OutlandAccount
{
    public string Email { get; set; }
    public string Name { get; set; }
    public string Salt { get; set; }
    public string PasswordHash { get; set; }
}

public sealed class OutlandRoomHost
{
    private readonly string root;
    private readonly string accountsPath;
    private readonly string prefix;
    private readonly HttpListener listener = new HttpListener();
    private readonly JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = 16384 };
    private readonly ConcurrentDictionary<string, ConcurrentDictionary<string, OutlandPeer>> rooms = new ConcurrentDictionary<string, ConcurrentDictionary<string, OutlandPeer>>();
    private readonly ConcurrentDictionary<string, OutlandAccount> sessions = new ConcurrentDictionary<string, OutlandAccount>();
    private readonly Dictionary<string, OutlandAccount> accounts = new Dictionary<string, OutlandAccount>(StringComparer.OrdinalIgnoreCase);
    private readonly object accountGate = new object();

    public OutlandRoomHost(string root, string prefix, string accountsPath)
    {
        this.root = root;
        this.accountsPath = accountsPath;
        this.prefix = prefix;
        listener.Prefixes.Add(prefix);
        LoadAccounts();
    }

    public async Task RunAsync()
    {
        listener.Start();
        Console.WriteLine("OUTLAND multiplayer server is listening at " + prefix);
        while (listener.IsListening)
        {
            HttpListenerContext context = await listener.GetContextAsync().ConfigureAwait(false);
            Task ignored = HandleAsync(context);
        }
    }

    private async Task HandleAsync(HttpListenerContext context)
    {
        try
        {
            if (!context.Request.IsWebSocketRequest)
            {
                string path = context.Request.Url.AbsolutePath;
                if (path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase))
                {
                    await HandleApiAsync(context).ConfigureAwait(false);
                    return;
                }
                if (path == "/health")
                {
                    await WriteResponse(context, 200, "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}"));
                    return;
                }
                if (path != "/" && !path.Equals("/INDEX.HTML", StringComparison.OrdinalIgnoreCase))
                {
                    await WriteResponse(context, 404, "text/plain", Encoding.UTF8.GetBytes("Not found"));
                    return;
                }
                byte[] page = File.ReadAllBytes(Path.Combine(root, "INDEX.HTML"));
                await WriteResponse(context, 200, "text/html; charset=utf-8", page);
                return;
            }

            HttpListenerWebSocketContext accepted = await context.AcceptWebSocketAsync(null).ConfigureAwait(false);
            OutlandPeer peer = new OutlandPeer { Socket = accepted.WebSocket };
            await ReceiveLoop(peer).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            Console.WriteLine("Request ended: " + error.Message);
            try { context.Response.Close(); } catch { }
        }
    }

    private static async Task WriteResponse(HttpListenerContext context, int status, string contentType, byte[] body)
    {
        context.Response.StatusCode = status;
        context.Response.ContentType = contentType;
        context.Response.ContentLength64 = body.Length;
        context.Response.Headers["Cache-Control"] = "no-store";
        await context.Response.OutputStream.WriteAsync(body, 0, body.Length).ConfigureAwait(false);
        context.Response.Close();
    }

    private async Task WriteJsonResponse(HttpListenerContext context, int status, object value)
    {
        byte[] body = Encoding.UTF8.GetBytes(serializer.Serialize(value));
        await WriteResponse(context, status, "application/json; charset=utf-8", body).ConfigureAwait(false);
    }

    private void LoadAccounts()
    {
        if (!File.Exists(accountsPath)) return;
        List<OutlandAccount> saved = serializer.Deserialize<List<OutlandAccount>>(File.ReadAllText(accountsPath, Encoding.UTF8));
        if (saved == null) return;
        foreach (OutlandAccount account in saved)
            if (account != null && !String.IsNullOrEmpty(account.Email)) accounts[account.Email] = account;
    }

    private void SaveAccounts()
    {
        List<OutlandAccount> saved = new List<OutlandAccount>(accounts.Values);
        File.WriteAllText(accountsPath, serializer.Serialize(saved), Encoding.UTF8);
    }

    private async Task HandleApiAsync(HttpListenerContext context)
    {
        if (context.Request.HttpMethod != "POST")
        {
            await WriteJsonResponse(context, 405, new { error = "POST required." }).ConfigureAwait(false);
            return;
        }
        if (context.Request.ContentLength64 > 8192)
        {
            await WriteJsonResponse(context, 413, new { error = "Request too large." }).ConfigureAwait(false);
            return;
        }

        try
        {
            string body;
            using (MemoryStream stream = new MemoryStream())
            {
                await context.Request.InputStream.CopyToAsync(stream).ConfigureAwait(false);
                if (stream.Length > 8192) throw new InvalidDataException("Request too large.");
                body = Encoding.UTF8.GetString(stream.ToArray());
            }
            Dictionary<string, object> data = serializer.Deserialize<Dictionary<string, object>>(body);
            string email = Text(data, "email").Trim().ToLowerInvariant();
            string password = Text(data, "password");
            string path = context.Request.Url.AbsolutePath.ToLowerInvariant();

            if (path == "/api/register")
            {
                string name = Text(data, "name").Trim();
                bool validEmail = true;
                try { new MailAddress(email); }
                catch { validEmail = false; }
                if (!validEmail)
                {
                    await WriteJsonResponse(context, 400, new { error = "Enter a valid email address." }).ConfigureAwait(false);
                    return;
                }
                if (email.Length > 254 || !Regex.IsMatch(name, "^[A-Za-z0-9_-]{3,16}$"))
                {
                    await WriteJsonResponse(context, 400, new { error = "Choose an operator name with 3-16 letters, numbers, _ or -." }).ConfigureAwait(false);
                    return;
                }
                if (password.Length < 8 || password.Length > 128)
                {
                    await WriteJsonResponse(context, 400, new { error = "Password must be 8-128 characters." }).ConfigureAwait(false);
                    return;
                }

                OutlandAccount account;
                byte[] salt = new byte[16];
                using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(salt);
                account = new OutlandAccount { Email = email, Name = name, Salt = Convert.ToBase64String(salt), PasswordHash = HashPassword(password, salt) };
                bool alreadyExists;
                lock (accountGate)
                {
                    alreadyExists = accounts.ContainsKey(email);
                    if (!alreadyExists)
                    {
                        accounts[email] = account;
                        SaveAccounts();
                    }
                }
                if (alreadyExists)
                {
                    await WriteJsonResponse(context, 409, new { error = "An account with that email already exists." }).ConfigureAwait(false);
                    return;
                }
                await WriteJsonResponse(context, 201, new { token = CreateSession(account), name = account.Name, email = account.Email }).ConfigureAwait(false);
                return;
            }

            if (path == "/api/login")
            {
                OutlandAccount account;
                lock (accountGate) accounts.TryGetValue(email, out account);
                if (account == null || !VerifyPassword(password, account))
                {
                    await WriteJsonResponse(context, 401, new { error = "Email or password is incorrect." }).ConfigureAwait(false);
                    return;
                }
                await WriteJsonResponse(context, 200, new { token = CreateSession(account), name = account.Name, email = account.Email }).ConfigureAwait(false);
                return;
            }

            await WriteJsonResponse(context, 404, new { error = "Unknown account endpoint." }).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            Console.WriteLine("Account request failed: " + error.Message);
            if (!context.Response.OutputStream.CanWrite) return;
        }
        await WriteJsonResponse(context, 500, new { error = "Account service is unavailable." }).ConfigureAwait(false);
    }

    private static string HashPassword(string password, byte[] salt)
    {
        using (Rfc2898DeriveBytes derivation = new Rfc2898DeriveBytes(password, salt, 180000))
            return Convert.ToBase64String(derivation.GetBytes(32));
    }

    private static bool VerifyPassword(string password, OutlandAccount account)
    {
        try
        {
            byte[] expected = Convert.FromBase64String(account.PasswordHash);
            byte[] actual = Convert.FromBase64String(HashPassword(password, Convert.FromBase64String(account.Salt)));
            if (expected.Length != actual.Length) return false;
            int mismatch = 0;
            for (int i = 0; i < expected.Length; i++) mismatch |= expected[i] ^ actual[i];
            return mismatch == 0;
        }
        catch { return false; }
    }

    private string CreateSession(OutlandAccount account)
    {
        byte[] tokenBytes = new byte[32];
        using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(tokenBytes);
        string token = Convert.ToBase64String(tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        sessions[token] = account;
        return token;
    }

    private async Task ReceiveLoop(OutlandPeer peer)
    {
        byte[] buffer = new byte[4096];
        try
        {
            while (peer.Socket.State == WebSocketState.Open)
            {
                using (MemoryStream message = new MemoryStream())
                {
                    WebSocketReceiveResult result;
                    do
                    {
                        result = await peer.Socket.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None).ConfigureAwait(false);
                        if (result.MessageType == WebSocketMessageType.Close) return;
                        message.Write(buffer, 0, result.Count);
                        if (message.Length > 8192) throw new InvalidDataException("Message too large");
                    } while (!result.EndOfMessage);

                    Dictionary<string, object> data = serializer.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(message.ToArray()));
                    if (data != null) await HandleMessage(peer, data).ConfigureAwait(false);
                }
            }
        }
        catch (Exception error)
        {
            if (peer.Socket.State == WebSocketState.Open) Console.WriteLine("Client ended: " + error.Message);
        }
        finally
        {
            RemovePeer(peer);
            try
            {
                if (peer.Socket.State == WebSocketState.Open || peer.Socket.State == WebSocketState.CloseReceived)
                    peer.Socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Room closed", CancellationToken.None).GetAwaiter().GetResult();
            }
            catch { }
        }
    }

    private async Task HandleMessage(OutlandPeer peer, Dictionary<string, object> data)
    {
        string type = Text(data, "type");
        if (type == "join")
        {
            string roomName = Text(data, "room").ToUpperInvariant();
            if (!Regex.IsMatch(roomName, "^[A-Z0-9_-]{2,12}$")) roomName = "OUTLAND";
            OutlandAccount account;
            if (!sessions.TryGetValue(Text(data, "token"), out account))
            {
                await Send(peer, new { type = "error", message = "Sign in with your email to enter a room." });
                return;
            }
            ConcurrentDictionary<string, OutlandPeer> room = rooms.GetOrAdd(roomName, _ => new ConcurrentDictionary<string, OutlandPeer>());
            if (room.Count >= 50)
            {
                await Send(peer, new { type = "error", message = "Room is full (50 operators maximum)." });
                return;
            }

            string mode = Text(data, "mode").ToLowerInvariant();
            if (mode != "teams" && mode != "survival" && mode != "battle-royale") mode = "ffa";
            foreach (OutlandPeer other in room.Values)
            {
                if (other.Mode != mode)
                {
                    string modeName = other.Mode == "teams" ? "TEAM BATTLE" : other.Mode == "survival" ? "SURVIVAL" : other.Mode == "battle-royale" ? "BATTLE ROYALE" : "FREE FOR ALL";
                    await Send(peer, new { type = "error", message = "This room is running " + modeName + ". Choose the same mode or use another room code." });
                    return;
                }
            }

            peer.Id = Guid.NewGuid().ToString("N").Substring(0, 8);
            peer.Room = roomName;
            peer.Name = account.Name;
            peer.Email = account.Email;
            peer.Mode = mode;
            peer.DropSite = NormalizeDropSite(Text(data, "dropSite"));
            peer.Weapon = NormalizeWeapon(Text(data, "weapon"));
            if (mode == "teams")
            {
                int teamZero = 0, teamOne = 0;
                foreach (OutlandPeer other in room.Values)
                    if (other.Team == 0) teamZero++; else if (other.Team == 1) teamOne++;
                peer.Team = teamZero <= teamOne ? 0 : 1;
            }
            int spawnIndex = -1;
            for (int candidate = 0; candidate < 50; candidate++)
            {
                double angle = Math.PI * 2 * candidate / 50;
                double candidateX = DropCenterX(peer.DropSite) + Math.Cos(angle) * 13;
                double candidateZ = DropCenterZ(peer.DropSite) + Math.Sin(angle) * 13;
                bool occupied = false;
                foreach (OutlandPeer other in room.Values)
                {
                    double dx = other.X - candidateX, dz = other.Z - candidateZ;
                    if (other.DropSite == peer.DropSite && dx * dx + dz * dz < 1.44) { occupied = true; break; }
                }
                if (!occupied) { spawnIndex = candidate; peer.X = candidateX; peer.Z = candidateZ; break; }
            }
            if (spawnIndex < 0)
            {
                await Send(peer, new { type = "error", message = "This drop site is full. Choose another region or room." });
                return;
            }
            string color = Text(data, "color");
            if (Regex.IsMatch(color, "^#[0-9a-fA-F]{6}$")) peer.Color = color;
            room[peer.Id] = peer;
            List<object> existing = new List<object>();
            foreach (OutlandPeer other in room.Values)
                if (other.Id != peer.Id) existing.Add(Snapshot(other));
            await Send(peer, new { type = "welcome", id = peer.Id, room = roomName, mode = peer.Mode, team = peer.Team, dropSite = peer.DropSite, dropName = DropSiteName(peer.DropSite), spawnX = peer.X, spawnZ = peer.Z, players = existing });
            await Broadcast(roomName, new { type = "playerJoined", player = Snapshot(peer) }, peer.Id);
            Console.WriteLine(peer.Id + " joined room " + roomName + " (" + room.Count + " operators)");
            return;
        }

        if (String.IsNullOrEmpty(peer.Room)) return;
        if (type == "state")
        {
            peer.X = Number(data, "x", peer.X, -43, 43);
            peer.Z = Number(data, "z", peer.Z, -35, 35);
            peer.Y = Number(data, "y", peer.Y, -1, 40);
            peer.Yaw = Number(data, "yaw", peer.Yaw, -1000, 1000);
            string color = Text(data, "color");
            if (Regex.IsMatch(color, "^#[0-9a-fA-F]{6}$")) peer.Color = color;
            peer.Weapon = NormalizeWeapon(Text(data, "weapon"));
            await Broadcast(peer.Room, new { type = "playerState", player = Snapshot(peer) }, peer.Id);
        }
        else if (type == "shot")
        {
            await Broadcast(peer.Room, new { type = "playerShot", id = peer.Id, from = data.ContainsKey("from") ? data["from"] : null, to = data.ContainsKey("to") ? data["to"] : null }, peer.Id);
        }
        else if (type == "hit")
        {
            string targetId = Text(data, "targetId");
            ConcurrentDictionary<string, OutlandPeer> room;
            OutlandPeer target;
            if ((DateTime.UtcNow - peer.LastHit).TotalMilliseconds < WeaponCooldown(peer.Weapon) ||
                !rooms.TryGetValue(peer.Room, out room) || !room.TryGetValue(targetId, out target) ||
                peer.Mode == "survival" || target.Id == peer.Id || target.Health <= 0 || Distance(peer, target) > WeaponRange(peer.Weapon) ||
                (peer.Mode == "teams" && target.Team == peer.Team)) return;

            peer.LastHit = DateTime.UtcNow;
            target.Health = Math.Max(0, target.Health - WeaponDamage(peer.Weapon));
            await Broadcast(peer.Room, new { type = "playerDamaged", targetId = target.Id, health = target.Health, attackerId = peer.Id }, null);
        }
        else if (type == "damage")
        {
            if (peer.Mode != "survival" || (DateTime.UtcNow - peer.LastDamage).TotalMilliseconds < 600 || peer.Health <= 0) return;
            peer.LastDamage = DateTime.UtcNow;
            int amount = (int)Number(data, "amount", 5, 1, 12);
            peer.Health = Math.Max(0, peer.Health - amount);
            await Broadcast(peer.Room, new { type = "playerDamaged", targetId = peer.Id, health = peer.Health, attackerId = "hostile" }, null);
        }
        else if (type == "respawn")
        {
            peer.Health = 100;
            await Broadcast(peer.Room, new { type = "playerRespawned", player = Snapshot(peer) }, null);
        }
        else if (type == "down")
        {
            peer.Health = 0;
            await Broadcast(peer.Room, new { type = "playerDamaged", targetId = peer.Id, health = 0, attackerId = "" }, null);
        }
    }

    private static double Distance(OutlandPeer a, OutlandPeer b)
    {
        double dx = a.X - b.X, dz = a.Z - b.Z;
        return Math.Sqrt(dx * dx + dz * dz);
    }

    private static string NormalizeWeapon(string weapon)
    {
        return weapon == "smg" || weapon == "dmr" || weapon == "shotgun" ? weapon : "rifle";
    }

    private static string NormalizeDropSite(string site)
    {
        return site == "boneyard" || site == "red-mesa" || site == "oasis" || site == "dust-town" || site == "iron-quarry" ? site : "ash-harbor";
    }

    private static string DropSiteName(string site)
    {
        return site == "boneyard" ? "The Boneyard" : site == "red-mesa" ? "Red Mesa" : site == "oasis" ? "Palm Oasis" : site == "dust-town" ? "Dust Town" : site == "iron-quarry" ? "Iron Quarry" : "Ash Harbor";
    }

    private static double DropCenterX(string site)
    {
        return site == "ash-harbor" || site == "oasis" ? -27 : site == "red-mesa" || site == "iron-quarry" ? 27 : 0;
    }

    private static double DropCenterZ(string site)
    {
        return site == "ash-harbor" || site == "boneyard" || site == "red-mesa" ? -21 : 21;
    }

    private static int WeaponDamage(string weapon)
    {
        return weapon == "smg" ? 22 : weapon == "dmr" ? 50 : weapon == "shotgun" ? 70 : 34;
    }

    private static int WeaponCooldown(string weapon)
    {
        return weapon == "smg" ? 85 : weapon == "dmr" ? 360 : weapon == "shotgun" ? 620 : 125;
    }

    private static double WeaponRange(string weapon)
    {
        return weapon == "smg" ? 35 : weapon == "dmr" ? 75 : weapon == "shotgun" ? 20 : 58;
    }

    private static object Snapshot(OutlandPeer peer)
    {
        return new { id = peer.Id, name = peer.Name, x = peer.X, y = peer.Y, z = peer.Z, yaw = peer.Yaw, color = peer.Color, health = peer.Health, team = peer.Team, mode = peer.Mode, dropSite = peer.DropSite, weapon = peer.Weapon };
    }

    private static string Text(Dictionary<string, object> data, string key)
    {
        object value;
        return data.TryGetValue(key, out value) && value != null ? Convert.ToString(value, CultureInfo.InvariantCulture) : "";
    }

    private static double Number(Dictionary<string, object> data, string key, double fallback, double min, double max)
    {
        object value;
        double parsed;
        if (!data.TryGetValue(key, out value) || !Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) || Double.IsNaN(parsed) || Double.IsInfinity(parsed)) return fallback;
        return Math.Max(min, Math.Min(max, parsed));
    }

    private async Task Send(OutlandPeer peer, object value)
    {
        if (peer.Socket.State != WebSocketState.Open) return;
        byte[] bytes = Encoding.UTF8.GetBytes(serializer.Serialize(value));
        await peer.SendGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (peer.Socket.State == WebSocketState.Open)
                await peer.Socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None).ConfigureAwait(false);
        }
        finally { peer.SendGate.Release(); }
    }

    private async Task Broadcast(string roomName, object value, string exceptId)
    {
        ConcurrentDictionary<string, OutlandPeer> room;
        if (!rooms.TryGetValue(roomName, out room)) return;
        List<Task> sends = new List<Task>();
        foreach (OutlandPeer peer in room.Values)
            if (peer.Id != exceptId) sends.Add(Send(peer, value));
        await Task.WhenAll(sends).ConfigureAwait(false);
    }

    private void RemovePeer(OutlandPeer peer)
    {
        if (String.IsNullOrEmpty(peer.Room)) return;
        ConcurrentDictionary<string, OutlandPeer> room;
        if (rooms.TryGetValue(peer.Room, out room))
        {
            OutlandPeer removed;
            room.TryRemove(peer.Id, out removed);
            Task ignored = Broadcast(peer.Room, new { type = "playerLeft", id = peer.Id }, null);
            if (room.IsEmpty)
            {
                ConcurrentDictionary<string, OutlandPeer> unused;
                rooms.TryRemove(peer.Room, out unused);
            }
        }
        Console.WriteLine(peer.Id + " left room " + peer.Room);
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Web.Extensions'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$prefix = if ($env:OUTLAND_PREFIX) { $env:OUTLAND_PREFIX } else {
    $port = 3000
    while ($true) {
        $probe = $null
        try {
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
            $probe.Start()
            break
        }
        catch {
            $port++
        }
        finally {
            if ($null -ne $probe) { $probe.Stop() }
        }
    }
    "http://localhost:$port/"
}
Write-Host "OUTLAND server prefix: $prefix"
$accountFolder = Join-Path $env:LOCALAPPDATA 'Outland'
if ($env:OUTLAND_ACCOUNT_PATH) { $accountPath = $env:OUTLAND_ACCOUNT_PATH }
else { $accountPath = Join-Path $accountFolder 'accounts.json' }
New-Item -ItemType Directory -Path (Split-Path -Parent $accountPath) -Force | Out-Null
$roomServer = New-Object OutlandRoomHost($root, $prefix, $accountPath)
$roomServer.RunAsync().GetAwaiter().GetResult()