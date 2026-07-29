{$apptype console}
{$reference System.dll}
{$reference System.Net.dll}

uses
  System,
  System.Net,
  System.Net.Sockets,
  System.Threading,
  System.Collections.Generic,
  System.IO,
  System.Text.RegularExpressions;

const
  SERVER_PORT = 12345;
  DISCOVERY_PORT = 12346;
  SCREEN_PORT = 12347;
  MAX_ROOMS = 11;
  MUTE_ROOM_ID = 11;
  USERS_FILE = 'passw\users.txt';
  HEARTBEAT_TIMEOUT = 15000;

  LOG_DIR = 'logs';
  STATS_LOG_FILE = 'logs\server_stats.log';
  EVENT_LOG_FILE = 'logs\server_events.log';
  STATS_FLUSH_INTERVAL_MS = 60000;

  CHAT_DIR = 'chat';
  GLOBAL_CHAT_FILE = 'chat\global_chat.txt';
  
  // Константы для защиты
  MAX_LOGIN_ATTEMPTS = 5;
  BAN_DURATION_HOURS = 1;
  CHAT_COOLDOWN_MS = 500; // 0.5 секунды
  MESSAGE_LIMIT_PER_HOUR = 500000; // 8 МБ в час
  MAX_REGISTRATIONS_PER_HOUR = 3; // Максимум регистраций с одного IP за час

type
  // Сначала объявляем все типы
  BanInfoType = class
  public
    IP: string;
    BanUntil: DateTime;
    Reason: string;
  end;

  ClientInfo = class
  public
    Endpoint: IPEndPoint;
    LastSeen: DateTime;
    LastHeartbeat: DateTime;
    JoinTime: DateTime;
    RoomID: integer;
    Username: string;
    IsAuthenticated: boolean;
    ClientIP: string;
    ClientPort: integer;

    PacketsReceived: int64;
    BytesReceived: int64;
    PacketsSent: int64;
    BytesSent: int64;

    SnapshotPacketsReceived: int64;
    SnapshotBytesReceived: int64;
    SnapshotPacketsSent: int64;
    SnapshotBytesSent: int64;
    
    IsScreenSharing: boolean;
    ScreenPort: integer;
    
    // Для защиты от флуда
    LastChatMessageTime: DateTime;
    LastChatMessageText: string;
    ChatMessageCount: integer;
    ChatTotalBytes: int64;
    ChatHourStart: DateTime;
  end;

  RoomInfo = class
  public
    ID: integer;
    Name: string;
    Clients: Dictionary<string, ClientInfo>;
  end;

  UserAccount = class
  public
    Username: string;
    Password: string;
    CreatedAt: DateTime;
    LastLogin: DateTime;
    LastIP: string;
    LastLoginAttempt: DateTime;
    LoginAttempts: integer;
    IsBanned: boolean;
    BanExpires: DateTime;
    LastRegisterAttempt: DateTime;
    RegistrationCount: integer;  // Счетчик регистраций за час
    RegistrationWindowStart: DateTime;  // Начало окна для подсчета
  end;

var
  Server: UdpClient;
  ScreenServer: UdpClient;
  Rooms: array[1..MAX_ROOMS] of RoomInfo;
  Clients: Dictionary<string, ClientInfo>;
  Users: Dictionary<string, UserAccount>;
  BannedIPs: Dictionary<string, BanInfoType>;

  RecvThread: Thread;
  ScreenRecvThread: Thread;
  DiscoveryThread: Thread;
  HeartbeatThread: Thread;
  StatsLogThread: Thread;

  IsRunning: boolean;
  IsDiscovering: boolean;

  ServerPortValue: integer;
  ScreenPortValue: integer;

  LogSync: object;

  TotalPacketsReceived: int64;
  TotalBytesReceived: int64;
  TotalPacketsSent: int64;
  TotalBytesSent: int64;

  ScreenTotalPacketsReceived: int64;
  ScreenTotalBytesReceived: int64;
  ScreenTotalPacketsSent: int64;
  ScreenTotalBytesSent: int64;

function BoolToStr(b: boolean): string;
begin
  if b then Result := 'true' else Result := 'false';
end;

procedure EnsureDirectoryExists();
begin
  if not System.IO.Directory.Exists('passw') then
    System.IO.Directory.CreateDirectory('passw');
end;

procedure EnsureLogDirectoryExists();
begin
  if not System.IO.Directory.Exists(LOG_DIR) then
    System.IO.Directory.CreateDirectory(LOG_DIR);
end;

procedure EnsureChatDirectoryExists();
begin
  if not System.IO.Directory.Exists(CHAT_DIR) then
    System.IO.Directory.CreateDirectory(CHAT_DIR);
end;

function RoomChatFileName(roomID: integer): string;
begin
  Result := CHAT_DIR + '\room_' + IntToStr(roomID) + '.txt';
end;

function NowText(): string;
begin
  Result := DateTime.Now.ToString('yyyy-MM-dd HH:mm:ss');
end;

procedure AppendLineToFile(fileName, line: string);
var
  sw: StreamWriter;
begin
  lock LogSync do
  begin
    sw := new StreamWriter(fileName, true, System.Text.Encoding.UTF8);
    try
      sw.WriteLine(line);
    finally
      sw.Close();
    end;
  end;
end;

procedure LogEvent(line: string);
begin
  EnsureLogDirectoryExists();
  AppendLineToFile(EVENT_LOG_FILE, NowText() + ' | ' + line);
end;

procedure LogStatsSnapshot();
var
  sw: StreamWriter;
  keysArr: array of string;
  i: integer;
  clientData: ClientInfo;
  deltaPacketsIn: int64;
  deltaBytesIn: int64;
  deltaPacketsOut: int64;
  deltaBytesOut: int64;
begin
  EnsureLogDirectoryExists();

  lock LogSync do
  begin
    sw := new StreamWriter(STATS_LOG_FILE, true, System.Text.Encoding.UTF8);
    try
      sw.WriteLine('============================================================');
      sw.WriteLine(NowText());
      sw.WriteLine('TOTAL | recv_packets=' + IntToStr(TotalPacketsReceived) +
                   ' recv_bytes=' + IntToStr(TotalBytesReceived) +
                   ' sent_packets=' + IntToStr(TotalPacketsSent) +
                   ' sent_bytes=' + IntToStr(TotalBytesSent));
      sw.WriteLine('SCREEN | recv_packets=' + IntToStr(ScreenTotalPacketsReceived) +
                   ' recv_bytes=' + IntToStr(ScreenTotalBytesReceived) +
                   ' sent_packets=' + IntToStr(ScreenTotalPacketsSent) +
                   ' sent_bytes=' + IntToStr(ScreenTotalBytesSent));

      keysArr := Clients.Keys.ToArray;
      for i := 0 to keysArr.Length - 1 do
      begin
        if not Clients.ContainsKey(keysArr[i]) then
          Continue;

        clientData := Clients[keysArr[i]];

        deltaPacketsIn := clientData.PacketsReceived - clientData.SnapshotPacketsReceived;
        deltaBytesIn := clientData.BytesReceived - clientData.SnapshotBytesReceived;
        deltaPacketsOut := clientData.PacketsSent - clientData.SnapshotPacketsSent;
        deltaBytesOut := clientData.BytesSent - clientData.SnapshotBytesSent;

        sw.WriteLine(
          'USER | username=' + clientData.Username +
          ' endpoint=' + clientData.Endpoint.Address.ToString() + ':' + IntToStr(clientData.Endpoint.Port) +
          ' room=' + IntToStr(clientData.RoomID) +
          ' screen=' + BoolToStr(clientData.IsScreenSharing) +
          ' screen_port=' + IntToStr(clientData.ScreenPort) +
          ' recv_packets_total=' + IntToStr(clientData.PacketsReceived) +
          ' recv_bytes_total=' + IntToStr(clientData.BytesReceived) +
          ' sent_packets_total=' + IntToStr(clientData.PacketsSent) +
          ' sent_bytes_total=' + IntToStr(clientData.BytesSent) +
          ' recv_packets_1m=' + IntToStr(deltaPacketsIn) +
          ' recv_bytes_1m=' + IntToStr(deltaBytesIn) +
          ' sent_packets_1m=' + IntToStr(deltaPacketsOut) +
          ' sent_bytes_1m=' + IntToStr(deltaBytesOut) +
          ' last_seen=' + clientData.LastSeen.ToString('yyyy-MM-dd HH:mm:ss')
        );

        clientData.SnapshotPacketsReceived := clientData.PacketsReceived;
        clientData.SnapshotBytesReceived := clientData.BytesReceived;
        clientData.SnapshotPacketsSent := clientData.PacketsSent;
        clientData.SnapshotBytesSent := clientData.BytesSent;
      end;

      sw.WriteLine('');
    finally
      sw.Close();
    end;
  end;
end;

procedure StatsLogLoop();
begin
  while IsRunning do
  begin
    Thread.Sleep(STATS_FLUSH_INTERVAL_MS);
    if IsRunning then
      LogStatsSnapshot();
  end;
end;

function MakeKey(ep: IPEndPoint): string;
begin
  Result := ep.Address.ToString() + ':' + IntToStr(ep.Port);
end;

procedure SendPacketToClient(ep: IPEndPoint; data: array of byte);
var
  key: string;
begin
  Server.Send(data, data.Length, ep);

  TotalPacketsSent := TotalPacketsSent + 1;
  TotalBytesSent := TotalBytesSent + data.Length;

  key := ep.Address.ToString() + ':' + IntToStr(ep.Port);
  if Clients.ContainsKey(key) then
  begin
    Clients[key].PacketsSent := Clients[key].PacketsSent + 1;
    Clients[key].BytesSent := Clients[key].BytesSent + data.Length;
  end;
end;

procedure SendScreenPacketToClient(ep: IPEndPoint; data: array of byte);
begin
  try
    ScreenServer.Send(data, data.Length, ep);
    ScreenTotalPacketsSent := ScreenTotalPacketsSent + 1;
    ScreenTotalBytesSent := ScreenTotalBytesSent + data.Length;
  except
    // Игнорируем ошибки отправки
  end;
end;

function EncodeTextBase64(s: string): string;
begin
  Result := Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(s));
end;

function DecodeTextBase64(s: string): string;
begin
  Result := System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(s));
end;

procedure AppendChatLine(fileName, userName, text: string);
var
  sw: StreamWriter;
begin
  EnsureChatDirectoryExists();

  lock LogSync do
  begin
    sw := new StreamWriter(fileName, true, System.Text.Encoding.UTF8);
    try
      sw.WriteLine(NowText() + '|' + userName + '|' + text);
    finally
      sw.Close();
    end;
  end;
end;

function LoadChatHistoryBase64(fileName: string): string;
var
  sr: StreamReader;
  allText: string;
begin
  EnsureChatDirectoryExists();

  if not System.IO.File.Exists(fileName) then
  begin
    Result := '';
    Exit;
  end;

  sr := new StreamReader(fileName, System.Text.Encoding.UTF8);
  try
    allText := sr.ReadToEnd();
  finally
    sr.Close();
  end;

  Result := EncodeTextBase64(allText);
end;

procedure SendGlobalChatHistory(clientKey: string);
var
  payload: string;
  data: array of byte;
begin
  if not Clients.ContainsKey(clientKey) then Exit;

  payload := LoadChatHistoryBase64(GLOBAL_CHAT_FILE);
  data := System.Text.Encoding.UTF8.GetBytes('CHAT_HISTORY_GLOBAL|' + payload);
  SendPacketToClient(Clients[clientKey].Endpoint, data);
end;

procedure SendRoomChatHistory(clientKey: string; roomID: integer);
var
  payload: string;
  data: array of byte;
begin
  if not Clients.ContainsKey(clientKey) then Exit;
  if (roomID < 1) or (roomID > MAX_ROOMS) then Exit;

  payload := LoadChatHistoryBase64(RoomChatFileName(roomID));
  data := System.Text.Encoding.UTF8.GetBytes('CHAT_HISTORY_ROOM|' + IntToStr(roomID) + '|' + payload);
  SendPacketToClient(Clients[clientKey].Endpoint, data);
end;

// Проверка на бан по IP
function IsIPBanned(ip: string): boolean;
var
  banData: BanInfoType;
begin
  Result := false;
  if BannedIPs.ContainsKey(ip) then
  begin
    banData := BannedIPs[ip];
    if DateTime.Now < banData.BanUntil then
      Result := true
    else
      BannedIPs.Remove(ip);
  end;
end;

// Добавление IP в бан-лист
procedure AddIPToBanList(ip: string; reason: string);
var
  banData: BanInfoType;
begin
  banData := new BanInfoType;
  banData.IP := ip;
  banData.BanUntil := DateTime.Now.AddHours(BAN_DURATION_HOURS);
  banData.Reason := reason;
  BannedIPs[ip] := banData;
  LogEvent('IP_BANNED ip=' + ip + ' reason=' + reason + ' until=' + banData.BanUntil.ToString());
end;

// Проверка валидности ника (только латиница, цифры, без пробелов)
function IsValidUsername(username: string): boolean;
begin
  Result := false;
  
  // Проверка длины
  if (Length(username) < 4) or (Length(username) > 18) then
  begin
    LogEvent('VALIDATION_FAIL username=' + username + ' reason=invalid_length');
    Exit;
  end;
  
  // Проверка на наличие кириллицы
  if Regex.IsMatch(username, '[а-яА-ЯёЁ]') then
  begin
    LogEvent('VALIDATION_FAIL username=' + username + ' reason=cyrillic_detected');
    Exit;
  end;
  
  // Проверка на допустимые символы (только латиница, цифры, подчеркивание)
  if not Regex.IsMatch(username, '^[a-zA-Z0-9_]+$') then
  begin
    LogEvent('VALIDATION_FAIL username=' + username + ' reason=invalid_characters');
    Exit;
  end;
  
  // ЗАПРЕТ: ник не должен состоять только из цифр
  if Regex.IsMatch(username, '^[0-9]+$') then
  begin
    LogEvent('VALIDATION_FAIL username=' + username + ' reason=only_digits');
    Exit;
  end;
  
  // ЗАПРЕТ: ник не должен содержать пробелы
  if username.Contains(' ') then
  begin
    LogEvent('VALIDATION_FAIL username=' + username + ' reason=contains_spaces');
    Exit;
  end;
  
  Result := true;
end;

// Проверка валидности пароля
function IsValidPassword(password: string): boolean;
begin
  Result := false;
  
  if Length(password) < 4 then
  begin
    LogEvent('VALIDATION_FAIL password_too_short');
    Exit;
  end;
  
  Result := true;
end;

procedure BroadcastGlobalChatLine(userName, text: string);
var
  keysArr: array of string;
  i: integer;
  data: array of byte;
begin
  AppendChatLine(GLOBAL_CHAT_FILE, userName, text);
  data := System.Text.Encoding.UTF8.GetBytes('CHAT_GLOBAL|' + EncodeTextBase64(NowText()) + '|' + EncodeTextBase64(userName) + '|' + EncodeTextBase64(text));

  keysArr := Clients.Keys.ToArray;
  for i := 0 to keysArr.Length - 1 do
    if Clients.ContainsKey(keysArr[i]) then
      SendPacketToClient(Clients[keysArr[i]].Endpoint, data);
end;

procedure BroadcastRoomChatLine(roomID: integer; userName, text: string);
var
  keysArr: array of string;
  i: integer;
  data: array of byte;
begin
  if (roomID < 1) or (roomID > MAX_ROOMS) then Exit;

  AppendChatLine(RoomChatFileName(roomID), userName, text);
  data := System.Text.Encoding.UTF8.GetBytes('CHAT_ROOM|' + IntToStr(roomID) + '|' + EncodeTextBase64(NowText()) + '|' + EncodeTextBase64(userName) + '|' + EncodeTextBase64(text));

  keysArr := Rooms[roomID].Clients.Keys.ToArray;
  for i := 0 to keysArr.Length - 1 do
    if Clients.ContainsKey(keysArr[i]) then
      SendPacketToClient(Clients[keysArr[i]].Endpoint, data);
end;

procedure BroadcastAllMention();
var
  keysArr: array of string;
  i: integer;
  data: array of byte;
begin
  data := System.Text.Encoding.UTF8.GetBytes('PLAY_ALL_SOUND');
  keysArr := Clients.Keys.ToArray;

  for i := 0 to keysArr.Length - 1 do
    if Clients.ContainsKey(keysArr[i]) then
      SendPacketToClient(Clients[keysArr[i]].Endpoint, data);
end;

procedure LoadUsers();
var
  sr: StreamReader;
  line: string;
  parts: array of string;
  user: UserAccount;
begin
  Users := new Dictionary<string, UserAccount>;
  BannedIPs := new Dictionary<string, BanInfoType>;
  EnsureDirectoryExists();

  if not System.IO.File.Exists(USERS_FILE) then Exit;

  sr := new StreamReader(USERS_FILE);
  try
    while not sr.EndOfStream do
    begin
      line := sr.ReadLine();
      if line = '' then Continue;

      parts := line.Split('|');
      if parts.Length >= 3 then
      begin
        user := new UserAccount;
        user.Username := parts[0];
        user.Password := parts[1];
        user.CreatedAt := DateTime.Parse(parts[2]);
        user.LastLogin := DateTime.Now;
        user.LastIP := '';
        user.LoginAttempts := 0;
        user.LastLoginAttempt := DateTime.Now;
        user.IsBanned := false;
        user.BanExpires := DateTime.Now;
        user.LastRegisterAttempt := DateTime.MinValue;
        user.RegistrationCount := 0; // Инициализируем счетчик
        user.RegistrationWindowStart := DateTime.Now;

        if parts.Length >= 4 then
          user.LastLogin := DateTime.Parse(parts[3]);
        if parts.Length >= 5 then
          user.LastIP := parts[4];

        Users[user.Username] := user;
      end;
    end;
  finally
    sr.Close();
  end;
end;

procedure SaveUsers();
var
  sw: StreamWriter;
  keysArr: array of string;
  i: integer;
  u: UserAccount;
begin
  EnsureDirectoryExists();

  sw := new StreamWriter(USERS_FILE);
  try
    keysArr := Users.Keys.ToArray;
    for i := 0 to keysArr.Length - 1 do
    begin
      u := Users[keysArr[i]];
      sw.WriteLine(
        u.Username + '|' +
        u.Password + '|' +
        u.CreatedAt.ToString() + '|' +
        u.LastLogin.ToString() + '|' +
        u.LastIP
      );
    end;
  finally
    sw.Close();
  end;
end;

function AuthenticateUser(username, password, clientIP: string): boolean;
var
  user: UserAccount;
begin
  Result := false;

  // Проверка на бан IP
  if IsIPBanned(clientIP) then
  begin
    LogEvent('AUTH_BLOCKED ip=' + clientIP + ' username=' + username + ' reason=ip_banned');
    Exit;
  end;

  if Users.TryGetValue(username, user) then
  begin
    // Проверка на бан пользователя
    if user.IsBanned and (DateTime.Now < user.BanExpires) then
    begin
      LogEvent('AUTH_BLOCKED username=' + username + ' reason=user_banned until=' + user.BanExpires.ToString());
      Exit;
    end
    else if user.IsBanned then
    begin
      user.IsBanned := false;
      user.LoginAttempts := 0;
    end;

    // Проверка на количество попыток
    if (DateTime.Now - user.LastLoginAttempt).TotalHours < BAN_DURATION_HOURS then
    begin
      if user.LoginAttempts >= MAX_LOGIN_ATTEMPTS then
      begin
        user.IsBanned := true;
        user.BanExpires := DateTime.Now.AddHours(BAN_DURATION_HOURS);
        AddIPToBanList(clientIP, 'too_many_login_attempts');
        LogEvent('USER_BANNED username=' + username + ' ip=' + clientIP + ' reason=too_many_attempts');
        SaveUsers();
        Exit;
      end;
    end
    else
    begin
      // Сброс счетчика попыток
      user.LoginAttempts := 0;
    end;

    if user.Password = password then
    begin
      user.LastLogin := DateTime.Now;
      user.LastIP := clientIP;
      user.LoginAttempts := 0;
      user.LastLoginAttempt := DateTime.Now;
      
      // Проверка на множественную авторизацию
      var keysArr := Clients.Keys.ToArray;
      for var i := 0 to keysArr.Length - 1 do
      begin
        if Clients.ContainsKey(keysArr[i]) and (Clients[keysArr[i]].Username = username) then
        begin
          LogEvent('DUPLICATE_LOGIN_ATTEMPT username=' + username + ' ip=' + clientIP + ' existing=' + Clients[keysArr[i]].ClientIP);
          Result := false;
          Exit;
        end;
      end;
      
      SaveUsers();
      Result := true;
    end
    else
    begin
      user.LoginAttempts := user.LoginAttempts + 1;
      user.LastLoginAttempt := DateTime.Now;
      SaveUsers();
      LogEvent('AUTH_FAILED username=' + username + ' ip=' + clientIP + ' attempts=' + IntToStr(user.LoginAttempts));
    end;
  end;
end;

function RegisterUser(username, password, clientIP: string): boolean;
var
  user: UserAccount;
  keysArr: array of string;
  i: integer;
  foundUser: UserAccount;
  now: DateTime;
  regCount: integer;
begin
  Result := false;
  now := DateTime.Now;

  // Проверка на бан IP
  if IsIPBanned(clientIP) then
  begin
    LogEvent('REGISTER_BLOCKED ip=' + clientIP + ' username=' + username + ' reason=ip_banned');
    Exit;
  end;

  // Проверка на частую регистрацию с одного IP (не более MAX_REGISTRATIONS_PER_HOUR за час)
  keysArr := Users.Keys.ToArray;
  
  // Сначала обновляем/сбрасываем счетчики у всех пользователей с этим IP
  for i := 0 to keysArr.Length - 1 do
  begin
    if Users[keysArr[i]].LastIP = clientIP then
    begin
      // Если окно истекло - сбрасываем счетчик
      if (now - Users[keysArr[i]].RegistrationWindowStart).TotalHours >= 1 then
      begin
        Users[keysArr[i]].RegistrationCount := 0;
        Users[keysArr[i]].RegistrationWindowStart := now;
        LogEvent('REGISTER_WINDOW_RESET ip=' + clientIP + ' user=' + Users[keysArr[i]].Username);
      end;
    end;
  end;

  // Считаем регистрации за последний час
  regCount := 0;
  for i := 0 to keysArr.Length - 1 do
  begin
    if (Users[keysArr[i]].LastIP = clientIP) and 
       ((now - Users[keysArr[i]].RegistrationWindowStart).TotalHours < 1) then
    begin
      regCount := regCount + Users[keysArr[i]].RegistrationCount;
    end;
  end;

  // Если с этого IP уже зарегистрировано MAX_REGISTRATIONS_PER_HOUR пользователей за час - блокируем
  if regCount >= MAX_REGISTRATIONS_PER_HOUR then
  begin
    LogEvent('REGISTER_LIMIT_EXCEEDED ip=' + clientIP + ' username=' + username + ' count=' + IntToStr(regCount) + ' in last hour (max=' + IntToStr(MAX_REGISTRATIONS_PER_HOUR) + ')');
    Exit;
  end;

  // Проверка на существование пользователя
  if Users.ContainsKey(username) then
  begin
    LogEvent('REGISTER_FAIL username=' + username + ' reason=already_exists');
    Exit;
  end;

  // Валидация ника
  if not IsValidUsername(username) then
  begin
    LogEvent('REGISTER_FAIL username=' + username + ' reason=invalid_username');
    Exit;
  end;

  // Валидация пароля
  if not IsValidPassword(password) then
  begin
    LogEvent('REGISTER_FAIL username=' + username + ' reason=invalid_password');
    Exit;
  end;

  // Если все проверки пройдены, создаем пользователя
  user := new UserAccount;
  user.Username := username;
  user.Password := password;
  user.CreatedAt := now;
  user.LastLogin := now;
  user.LastIP := clientIP;
  user.LoginAttempts := 0;
  user.LastLoginAttempt := now;
  user.IsBanned := false;
  user.BanExpires := now;
  user.LastRegisterAttempt := now;
  
  // Находим пользователя с этим IP, у которого есть активное окно
  foundUser := nil;
  for i := 0 to keysArr.Length - 1 do
  begin
    if (Users[keysArr[i]].LastIP = clientIP) and 
       ((now - Users[keysArr[i]].RegistrationWindowStart).TotalHours < 1) then
    begin
      foundUser := Users[keysArr[i]];
      Break;
    end;
  end;

  // Если нашли пользователя с активным окном - увеличиваем его счетчик
  if foundUser <> nil then
  begin
    foundUser.RegistrationCount := foundUser.RegistrationCount + 1;
    // Копируем данные окна в нового пользователя
    user.RegistrationCount := foundUser.RegistrationCount;
    user.RegistrationWindowStart := foundUser.RegistrationWindowStart;
    LogEvent('REGISTER_WINDOW_UPDATE ip=' + clientIP + ' user=' + username + ' count=' + IntToStr(user.RegistrationCount));
  end
  else
  begin
    // Если активного окна нет - создаем новое
    user.RegistrationCount := 1;
    user.RegistrationWindowStart := now;
    LogEvent('REGISTER_WINDOW_NEW ip=' + clientIP + ' user=' + username + ' count=1');
  end;

  Users[username] := user;
  SaveUsers();
  LogEvent('REGISTER_SUCCESS username=' + username + ' ip=' + clientIP + ' count_in_hour=' + IntToStr(user.RegistrationCount));
  Result := true;
end;

procedure InitRooms();
var
  i: integer;
begin
  for i := 1 to MAX_ROOMS do
  begin
    Rooms[i] := new RoomInfo;
    Rooms[i].ID := i;

    if i = MUTE_ROOM_ID then
      Rooms[i].Name := 'Mute'
    else
      Rooms[i].Name := 'Room ' + IntToStr(i);

    Rooms[i].Clients := new Dictionary<string, ClientInfo>;
  end;
end;

procedure UpdateStats();
var
  keysArray: array of string;
  i: integer;
  clientInfo: ClientInfo;
  host: IPHostEntry;
begin
  Console.Clear();
  Writeln('========== VOICE CHAT SERVER ==========');
  Writeln('Voice port: ' + IntToStr(ServerPortValue));
  Writeln('Screen port: ' + IntToStr(ScreenPortValue));
  Writeln('Discovery port: ' + IntToStr(DISCOVERY_PORT));
  Writeln('Registered users: ' + IntToStr(Users.Count));
  Writeln('Active clients: ' + IntToStr(Clients.Count));
  Writeln('Banned IPs: ' + IntToStr(BannedIPs.Count));
  Writeln('Voice packets received: ' + IntToStr(TotalPacketsReceived));
  Writeln('Voice bytes received: ' + IntToStr(TotalBytesReceived));
  Writeln('Voice packets sent: ' + IntToStr(TotalPacketsSent));
  Writeln('Voice bytes sent: ' + IntToStr(TotalBytesSent));
  Writeln('Screen packets received: ' + IntToStr(ScreenTotalPacketsReceived));
  Writeln('Screen bytes received: ' + IntToStr(ScreenTotalBytesReceived));
  Writeln('Screen packets sent: ' + IntToStr(ScreenTotalPacketsSent));
  Writeln('Screen bytes sent: ' + IntToStr(ScreenTotalBytesSent));
  Writeln;

  for i := 1 to MAX_ROOMS do
    if i = MUTE_ROOM_ID then
      Writeln('Mute room: ' + IntToStr(Rooms[i].Clients.Count) + ' client(s)')
    else
      Writeln('Room ' + IntToStr(i) + ': ' + IntToStr(Rooms[i].Clients.Count) + ' client(s)');

  Writeln;
  Writeln('Connected clients:');

  if Clients.Count = 0 then
    Writeln('  none')
  else
  begin
    keysArray := Clients.Keys.ToArray;
    for i := 0 to keysArray.Length - 1 do
    begin
      clientInfo := Clients[keysArray[i]];
      Writeln('  ' + clientInfo.Username + ' | ' +
              clientInfo.Endpoint.Address.ToString() + ':' + IntToStr(clientInfo.Endpoint.Port) +
              ' | room ' + IntToStr(clientInfo.RoomID) +
              ' | screen=' + BoolToStr(clientInfo.IsScreenSharing) +
              ' | screen_port=' + IntToStr(clientInfo.ScreenPort) +
              ' | recv=' + IntToStr(clientInfo.PacketsReceived) +
              ' | sent=' + IntToStr(clientInfo.PacketsSent));
    end;
  end;

  Writeln;
  host := Dns.GetHostEntry(Dns.GetHostName());
  for i := 0 to host.AddressList.Length - 1 do
    Writeln('IP: ' + host.AddressList[i].ToString());

  Writeln;
  Writeln('Commands:');
  Writeln('  q - quit');
  Writeln('  c - clear clients');
  Writeln('  b - show banned IPs');
end;

procedure SendUserListToClient(clientKey: string; roomID: integer);
var
  roomKeys: array of string;
  i: integer;
  listText: string;
  data: array of byte;
begin
  if not Clients.ContainsKey(clientKey) then Exit;
  if (roomID < 1) or (roomID > MAX_ROOMS) then Exit;

  roomKeys := Rooms[roomID].Clients.Keys.ToArray;
  listText := 'USER_LIST|';

  for i := 0 to roomKeys.Length - 1 do
  begin
    if Clients.ContainsKey(roomKeys[i]) then
      listText := listText + Clients[roomKeys[i]].Username + ',';
  end;

  data := System.Text.Encoding.UTF8.GetBytes(listText);
  SendPacketToClient(Clients[clientKey].Endpoint, data);
end;

procedure BroadcastUserListToRoom(roomID: integer);
var
  roomKeys: array of string;
  i: integer;
begin
  if (roomID < 1) or (roomID > MAX_ROOMS) then Exit;

  roomKeys := Rooms[roomID].Clients.Keys.ToArray;
  for i := 0 to roomKeys.Length - 1 do
    SendUserListToClient(roomKeys[i], roomID);
end;

procedure RemoveClientByKey(key: string);
var
  clientData: ClientInfo;
  roomID: integer;
begin
  if not Clients.ContainsKey(key) then Exit;

  clientData := Clients[key];
  roomID := clientData.RoomID;

  LogEvent(
    'DISCONNECT username=' + clientData.Username +
    ' endpoint=' + clientData.Endpoint.Address.ToString() + ':' + IntToStr(clientData.Endpoint.Port) +
    ' room=' + IntToStr(clientData.RoomID) +
    ' screen=' + BoolToStr(clientData.IsScreenSharing) +
    ' screen_port=' + IntToStr(clientData.ScreenPort) +
    ' recv_packets=' + IntToStr(clientData.PacketsReceived) +
    ' recv_bytes=' + IntToStr(clientData.BytesReceived) +
    ' sent_packets=' + IntToStr(clientData.PacketsSent) +
    ' sent_bytes=' + IntToStr(clientData.BytesSent)
  );

  if (roomID >= 1) and (roomID <= MAX_ROOMS) then
    if Rooms[roomID].Clients.ContainsKey(key) then
      Rooms[roomID].Clients.Remove(key);

  Clients.Remove(key);

  Writeln('[INFO] client removed: ' + key);
end;

procedure ChangeClientRoom(clientKey: string; newRoomID: integer);
var
  clientData: ClientInfo;
  oldRoomID: integer;
  data: array of byte;
begin
  if not Clients.ContainsKey(clientKey) then Exit;
  if (newRoomID < 1) or (newRoomID > MAX_ROOMS) then Exit;

  clientData := Clients[clientKey];
  oldRoomID := clientData.RoomID;

  if oldRoomID = newRoomID then Exit;

  if Rooms[oldRoomID].Clients.ContainsKey(clientKey) then
    Rooms[oldRoomID].Clients.Remove(clientKey);

  clientData.RoomID := newRoomID;
  Rooms[newRoomID].Clients[clientKey] := clientData;

  LogEvent(
    'ROOM_CHANGE username=' + clientData.Username +
    ' endpoint=' + clientData.Endpoint.Address.ToString() + ':' + IntToStr(clientData.Endpoint.Port) +
    ' from_room=' + IntToStr(oldRoomID) +
    ' to_room=' + IntToStr(newRoomID)
  );

  data := System.Text.Encoding.UTF8.GetBytes('ROOM_CHANGED|' + IntToStr(newRoomID));
  SendPacketToClient(clientData.Endpoint, data);

  BroadcastUserListToRoom(oldRoomID);
  BroadcastUserListToRoom(newRoomID);
  SendRoomChatHistory(clientKey, newRoomID);
end;

procedure DiscoveryResponseLoop();
var
  discoveryServer: UdpClient;
  remoteEP: IPEndPoint;
  data: array of byte;
  msg: string;
begin
  discoveryServer := new UdpClient(DISCOVERY_PORT);
  discoveryServer.Client.ReceiveTimeout := 500;

  while IsDiscovering do
  begin
    try
      remoteEP := new IPEndPoint(IPAddress.Any, 0);
      data := discoveryServer.Receive(remoteEP);
      msg := System.Text.Encoding.UTF8.GetString(data);

      if msg = 'WHO_IS_THERE?' then
      begin
        data := System.Text.Encoding.UTF8.GetBytes('SERVER_HERE|' + IntToStr(ServerPortValue));
        discoveryServer.Send(data, data.Length, remoteEP);
      end;
    except
    end;
  end;

  discoveryServer.Close();
end;

procedure HeartbeatLoop();
var
  keysArr: array of string;
  i: integer;
  clientData: ClientInfo;
  nowTime: DateTime;
  pingData: array of byte;
begin
  while IsRunning do
  begin
    Thread.Sleep(3000);
    nowTime := DateTime.Now;
    keysArr := Clients.Keys.ToArray;

    for i := 0 to keysArr.Length - 1 do
    begin
      if not Clients.ContainsKey(keysArr[i]) then Continue;

      clientData := Clients[keysArr[i]];

      if (nowTime - clientData.LastSeen).TotalMilliseconds > HEARTBEAT_TIMEOUT then
      begin
        Writeln('[TIMEOUT] ' + clientData.Username);
        RemoveClientByKey(keysArr[i]);
        BroadcastUserListToRoom(clientData.RoomID);
        UpdateStats();
      end
      else
      begin
        try
          pingData := System.Text.Encoding.UTF8.GetBytes('PING');
          SendPacketToClient(clientData.Endpoint, pingData);
        except
        end;
      end;
    end;
  end;
end;


// ПРИЕМ ГОЛОСОВЫХ ПАКЕТОВ


procedure ReceiveLoop();
var
  remoteEP: IPEndPoint;
  data: array of byte;
  confirmData: array of byte;
  msg: string;
  key: string;
  confirmMsg: string;
  username: string;
  password: string;
  clientIP: string;
  clientData: ClientInfo;
  roomID: integer;
  i: integer;
  newRoomID: integer;
  parts: array of string;
  roomClientsArray: array of string;
  textDecoded: string;
  keysArr: array of string;
  j: integer;
  textBytes: integer;
begin
  remoteEP := new IPEndPoint(IPAddress.Any, 0);

  while IsRunning do
  begin
    try
      data := Server.Receive(remoteEP);
      if (data = nil) or (data.Length = 0) then Continue;

      key := MakeKey(remoteEP);

      if data.Length <= 8192 then
      begin
        try
          msg := System.Text.Encoding.UTF8.GetString(data);

          if msg = 'PONG' then
          begin
            if Clients.ContainsKey(key) then
            begin
              Clients[key].LastHeartbeat := DateTime.Now;
              Clients[key].LastSeen := DateTime.Now;
              Clients[key].PacketsReceived := Clients[key].PacketsReceived + 1;
              Clients[key].BytesReceived := Clients[key].BytesReceived + data.Length;
              TotalPacketsReceived := TotalPacketsReceived + 1;
              TotalBytesReceived := TotalBytesReceived + data.Length;
            end;
            Continue;
          end;

          if msg.StartsWith('ROOM_CHANGE|') then
          begin
            if Clients.ContainsKey(key) then
            begin
              parts := msg.Split('|');
              if (parts.Length >= 2) and Integer.TryParse(parts[1], newRoomID) then
                ChangeClientRoom(key, newRoomID);
            end;
            Continue;
          end;

          if msg.StartsWith('CHAT_GLOBAL|') then
begin
  if Clients.ContainsKey(key) then
  begin
    parts := msg.Split('|');
    if parts.Length >= 2 then
    begin
      try
        textDecoded := DecodeTextBase64(parts[1]);
        
        // Проверка на флуд
        var client := Clients[key];
        if (DateTime.Now - client.LastChatMessageTime).TotalMilliseconds < CHAT_COOLDOWN_MS then
        begin
          LogEvent('CHAT_FLOOD_DETECTED username=' + client.Username + ' cooldown=' + IntToStr(CHAT_COOLDOWN_MS) + 'ms');
          Continue;
        end;
        
        // Проверка лимита сообщений (500к символов в час)
        if (DateTime.Now - client.ChatHourStart).TotalHours >= 1 then
        begin
          client.ChatTotalBytes := 0;
          client.ChatHourStart := DateTime.Now;
          LogEvent('CHAT_LIMIT_RESET username=' + client.Username);
        end;
        
        var charCount := textDecoded.Length;
        if client.ChatTotalBytes + charCount > MESSAGE_LIMIT_PER_HOUR then
        begin
          LogEvent('CHAT_LIMIT_EXCEEDED username=' + client.Username + ' limit=' + IntToStr(MESSAGE_LIMIT_PER_HOUR) + ' chars, current=' + IntToStr(client.ChatTotalBytes));
          Continue;
        end;
        
        client.LastChatMessageTime := DateTime.Now;
        client.ChatTotalBytes := client.ChatTotalBytes + charCount;
        
        BroadcastGlobalChatLine(client.Username, textDecoded);
        if textDecoded.Contains('@all') then
          BroadcastAllMention();
        //LogEvent('CHAT_GLOBAL username=' + client.Username + ' text=' + textDecoded + ' chars=' + IntToStr(charCount) + ' total=' + IntToStr(client.ChatTotalBytes));
      except
        on ex: Exception do
          LogEvent('CHAT_GLOBAL error: ' + ex.Message);
      end;
    end;
  end;
  Continue;
end;

          if msg.StartsWith('CHAT_ROOM|') then
begin
  if Clients.ContainsKey(key) then
  begin
    parts := msg.Split('|');
    if parts.Length >= 3 then
    begin
      if Integer.TryParse(parts[1], newRoomID) then
      begin
        try
          textDecoded := DecodeTextBase64(parts[2]);
          if Clients[key].RoomID = newRoomID then
          begin
            // Проверка на флуд
            var client := Clients[key];
            if (DateTime.Now - client.LastChatMessageTime).TotalMilliseconds < CHAT_COOLDOWN_MS then
            begin
              LogEvent('CHAT_FLOOD_DETECTED username=' + client.Username + ' cooldown=' + IntToStr(CHAT_COOLDOWN_MS) + 'ms');
              Continue;
            end;
            
            // Проверка лимита сообщений (500к символов в час)
            if (DateTime.Now - client.ChatHourStart).TotalHours >= 1 then
            begin
              client.ChatTotalBytes := 0;
              client.ChatHourStart := DateTime.Now;
              LogEvent('CHAT_LIMIT_RESET username=' + client.Username);
            end;
            
            var charCount := textDecoded.Length;
            if client.ChatTotalBytes + charCount > MESSAGE_LIMIT_PER_HOUR then
            begin
              LogEvent('CHAT_LIMIT_EXCEEDED username=' + client.Username + ' limit=' + IntToStr(MESSAGE_LIMIT_PER_HOUR) + ' chars, current=' + IntToStr(client.ChatTotalBytes));
              Continue;
            end;
            
            client.LastChatMessageTime := DateTime.Now;
            client.ChatTotalBytes := client.ChatTotalBytes + charCount;
            
            BroadcastRoomChatLine(newRoomID, client.Username, textDecoded);
           // LogEvent('CHAT_ROOM username=' + client.Username + ' room=' + IntToStr(newRoomID) + ' text=' + textDecoded + ' chars=' + IntToStr(charCount) + ' total=' + IntToStr(client.ChatTotalBytes));
          end;
        except
          on ex: Exception do
            LogEvent('CHAT_ROOM error: ' + ex.Message);
        end;
      end;
    end;
  end;
  Continue;
end;

          if msg.StartsWith('SCREEN_START|') then
          begin
            parts := msg.Split('|');
            if parts.Length >= 2 then
            begin
              username := parts[1];
              var screenPort := 0;
              if parts.Length >= 3 then
                Integer.TryParse(parts[2], screenPort);
              
              LogEvent('SCREEN_START via voice from ' + username + ' screen_port=' + IntToStr(screenPort));
              
              keysArr := Clients.Keys.ToArray;
              for i := 0 to keysArr.Length - 1 do
              begin
                if Clients.ContainsKey(keysArr[i]) and (Clients[keysArr[i]].Username = username) then
                begin
                  Clients[keysArr[i]].IsScreenSharing := true;
                  Clients[keysArr[i]].ScreenPort := screenPort;
                  LogEvent('SCREEN_START username=' + username + ' screen=true port=' + IntToStr(screenPort));
                  
                  // Отправляем уведомление всем в комнате через голосовой канал
                  roomID := Clients[keysArr[i]].RoomID;
                  if (roomID >= 1) and (roomID <= MAX_ROOMS) then
                  begin
                    var notifyData := System.Text.Encoding.UTF8.GetBytes('SCREEN_START|' + username);
                    roomClientsArray := Rooms[roomID].Clients.Keys.ToArray;
                    for j := 0 to roomClientsArray.Length - 1 do
                    begin
                      if roomClientsArray[j] <> keysArr[i] then
                      begin
                        try
                          SendPacketToClient(Rooms[roomID].Clients[roomClientsArray[j]].Endpoint, notifyData);
                          LogEvent('SCREEN_START notification sent to ' + Rooms[roomID].Clients[roomClientsArray[j]].Username);
                        except
                          on ex: Exception do
                            LogEvent('SCREEN_START forward error: ' + ex.Message);
                        end;
                      end;
                    end;
                  end;
                  
                  BroadcastUserListToRoom(roomID);
                  UpdateStats();
                  Break;
                end;
              end;
            end;
            Continue;
          end;

          if msg.StartsWith('SCREEN_STOP|') then
          begin
            parts := msg.Split('|');
            if parts.Length >= 2 then
            begin
              username := parts[1];
              LogEvent('SCREEN_STOP via voice from ' + username);
              
              keysArr := Clients.Keys.ToArray;
              for i := 0 to keysArr.Length - 1 do
              begin
                if Clients.ContainsKey(keysArr[i]) and (Clients[keysArr[i]].Username = username) then
                begin
                  Clients[keysArr[i]].IsScreenSharing := false;
                  Clients[keysArr[i]].ScreenPort := 0;
                  LogEvent('SCREEN_STOP username=' + username + ' screen=false');
                  
                  roomID := Clients[keysArr[i]].RoomID;
                  if (roomID >= 1) and (roomID <= MAX_ROOMS) then
                  begin
                    var notifyData := System.Text.Encoding.UTF8.GetBytes('SCREEN_STOP|' + username);
                    roomClientsArray := Rooms[roomID].Clients.Keys.ToArray;
                    for j := 0 to roomClientsArray.Length - 1 do
                    begin
                      if roomClientsArray[j] <> keysArr[i] then
                      begin
                        try
                          SendPacketToClient(Rooms[roomID].Clients[roomClientsArray[j]].Endpoint, notifyData);
                        except
                        end;
                      end;
                    end;
                  end;
                  
                  BroadcastUserListToRoom(roomID);
                  UpdateStats();
                  Break;
                end;
              end;
            end;
            Continue;
          end;

          // ===== ОБРАБОТКА SCREEN_VIEW =====
          if msg.StartsWith('SCREEN_VIEW|') then
          begin
            parts := msg.Split('|');
            if parts.Length >= 3 then
            begin
              username := parts[1];
              var screenPort := 0;
              if Integer.TryParse(parts[2], screenPort) then
              begin
                LogEvent('SCREEN_VIEW from ' + username + ' port=' + IntToStr(screenPort));
                
                keysArr := Clients.Keys.ToArray;
                for i := 0 to keysArr.Length - 1 do
                begin
                  if Clients.ContainsKey(keysArr[i]) and (Clients[keysArr[i]].Username = username) then
                  begin
                    Clients[keysArr[i]].ScreenPort := screenPort;
                    LogEvent('SCREEN_VIEW: set screen_port=' + IntToStr(screenPort) + ' for ' + username);
                    Break;
                  end;
                end;
              end;
            end;
            Continue;
          end;

          if msg.StartsWith('AUTH|') then
          begin
            parts := msg.Split('|');
            if parts.Length >= 3 then
            begin
              username := parts[1];
              password := parts[2];
              clientIP := remoteEP.Address.ToString();

              if AuthenticateUser(username, password, clientIP) then
              begin
                confirmMsg := 'AUTH_SUCCESS|' + username;
                confirmData := System.Text.Encoding.UTF8.GetBytes(confirmMsg);
                SendPacketToClient(remoteEP, confirmData);
              end
              else
              begin
                confirmMsg := 'AUTH_FAIL|Invalid credentials';
                confirmData := System.Text.Encoding.UTF8.GetBytes(confirmMsg);
                SendPacketToClient(remoteEP, confirmData);
              end;
            end;
            Continue;
          end;

          if msg.StartsWith('LOGIN|') then
          begin
            parts := msg.Split('|');
            if parts.Length >= 3 then
            begin
              username := parts[1];
              password := parts[2];
              clientIP := remoteEP.Address.ToString();

              if AuthenticateUser(username, password, clientIP) then
              begin
                if Clients.ContainsKey(key) then
                begin
                  clientData := Clients[key];
                  if Rooms[clientData.RoomID].Clients.ContainsKey(key) then
                    Rooms[clientData.RoomID].Clients.Remove(key);
                end;

                clientData := new ClientInfo;
                clientData.Endpoint := remoteEP;
                clientData.JoinTime := DateTime.Now;
                clientData.LastSeen := DateTime.Now;
                clientData.LastHeartbeat := DateTime.Now;
                clientData.RoomID := 1;
                clientData.Username := username;
                clientData.IsAuthenticated := true;
                clientData.ClientIP := clientIP;
                clientData.ClientPort := remoteEP.Port;
                clientData.IsScreenSharing := false;
                clientData.ScreenPort := 0;
                clientData.LastChatMessageTime := DateTime.Now;
                clientData.ChatHourStart := DateTime.Now;
                clientData.ChatTotalBytes := 0;

                clientData.PacketsReceived := 0;
                clientData.BytesReceived := 0;
                clientData.PacketsSent := 0;
                clientData.BytesSent := 0;

                clientData.SnapshotPacketsReceived := 0;
                clientData.SnapshotBytesReceived := 0;
                clientData.SnapshotPacketsSent := 0;
                clientData.SnapshotBytesSent := 0;

                Clients[key] := clientData;
                Rooms[1].Clients[key] := clientData;

                confirmMsg := 'LOGIN_SUCCESS|' + username;
                confirmData := System.Text.Encoding.UTF8.GetBytes(confirmMsg);
                SendPacketToClient(remoteEP, confirmData);

                LogEvent(
                  'CONNECT username=' + username +
                  ' endpoint=' + remoteEP.Address.ToString() + ':' + IntToStr(remoteEP.Port) +
                  ' room=1 method=LOGIN'
                );

                SendUserListToClient(key, 1);
                BroadcastUserListToRoom(1);
                SendGlobalChatHistory(key);
                SendRoomChatHistory(key, 1);
                UpdateStats();
              end
              else
              begin
                // Проверяем, не забанен ли IP
                if IsIPBanned(clientIP) then
                  confirmMsg := 'LOGIN_FAIL|IP banned'
                else
                  confirmMsg := 'LOGIN_FAIL|Invalid username or password';
                confirmData := System.Text.Encoding.UTF8.GetBytes(confirmMsg);
                SendPacketToClient(remoteEP, confirmData);
              end;
            end;
            Continue;
          end;

          if msg.StartsWith('REGISTER|') then
          begin
            parts := msg.Split('|');
            if parts.Length >= 3 then
            begin
              username := parts[1];
              password := parts[2];
              clientIP := remoteEP.Address.ToString();

              if RegisterUser(username, password, clientIP) then
              begin
                // УСПЕШНАЯ РЕГИСТРАЦИЯ
                if Clients.ContainsKey(key) then
                begin
                  clientData := Clients[key];
                  if Rooms[clientData.RoomID].Clients.ContainsKey(key) then
                    Rooms[clientData.RoomID].Clients.Remove(key);
                end;

                clientData := new ClientInfo;
                clientData.Endpoint := remoteEP;
                clientData.JoinTime := DateTime.Now;
                clientData.LastSeen := DateTime.Now;
                clientData.LastHeartbeat := DateTime.Now;
                clientData.RoomID := 1;
                clientData.Username := username;
                clientData.IsAuthenticated := true;
                clientData.ClientIP := clientIP;
                clientData.ClientPort := remoteEP.Port;
                clientData.IsScreenSharing := false;
                clientData.ScreenPort := 0;
                clientData.LastChatMessageTime := DateTime.Now;
                clientData.ChatHourStart := DateTime.Now;
                clientData.ChatTotalBytes := 0;

                clientData.PacketsReceived := 0;
                clientData.BytesReceived := 0;
                clientData.PacketsSent := 0;
                clientData.BytesSent := 0;

                clientData.SnapshotPacketsReceived := 0;
                clientData.SnapshotBytesReceived := 0;
                clientData.SnapshotPacketsSent := 0;
                clientData.SnapshotBytesSent := 0;

                Clients[key] := clientData;
                Rooms[1].Clients[key] := clientData;

                confirmMsg := 'REGISTER_SUCCESS|' + username;
                confirmData := System.Text.Encoding.UTF8.GetBytes(confirmMsg);
                SendPacketToClient(remoteEP, confirmData);

                LogEvent(
                  'CONNECT username=' + username +
                  ' endpoint=' + remoteEP.Address.ToString() + ':' + IntToStr(remoteEP.Port) +
                  ' room=1 method=REGISTER'
                );

                SendUserListToClient(key, 1);
                BroadcastUserListToRoom(1);
                SendGlobalChatHistory(key);
                SendRoomChatHistory(key, 1);
                UpdateStats();
                
                // После успешной регистрации пропускаем весь остальной код
                Continue;
              end
              else
              begin
                // НЕУДАЧНАЯ РЕГИСТРАЦИЯ
                if IsIPBanned(clientIP) then
                  confirmMsg := 'REGISTER_FAIL|IP banned'
                else if Users.ContainsKey(username) then
                  confirmMsg := 'REGISTER_FAIL|Username already exists'
                else if (Length(username) < 4) or (Length(username) > 18) then
                  confirmMsg := 'REGISTER_FAIL|Username must be 4-18 characters'
                else if Regex.IsMatch(username, '[а-яА-ЯёЁ]') then
                  confirmMsg := 'REGISTER_FAIL|Only Latin letters allowed'
                else if username.Contains(' ') then
                  confirmMsg := 'REGISTER_FAIL|Username cannot contain spaces'
                else if Regex.IsMatch(username, '^[0-9]+$') then
                  confirmMsg := 'REGISTER_FAIL|Username cannot be only digits'
                else if not Regex.IsMatch(username, '^[a-zA-Z0-9_]+$') then
                  confirmMsg := 'REGISTER_FAIL|Only letters, numbers and underscore allowed'
                else if Length(password) < 4 then
                  confirmMsg := 'REGISTER_FAIL|Password must be at least 4 characters'
                else
                  confirmMsg := 'REGISTER_FAIL|Registration failed';
                  
                confirmData := System.Text.Encoding.UTF8.GetBytes(confirmMsg);
                SendPacketToClient(remoteEP, confirmData);
                
                Continue;
              end;
            end;
            Continue;
          end;
        except
          on ex: Exception do
            LogEvent('ReceiveLoop parse error: ' + ex.Message);
        end;
      end;

      if Clients.ContainsKey(key) then
      begin
        clientData := Clients[key];
        if clientData.IsAuthenticated then
        begin
          TotalPacketsReceived := TotalPacketsReceived + 1;
          TotalBytesReceived := TotalBytesReceived + data.Length;

          clientData.LastSeen := DateTime.Now;
          clientData.LastHeartbeat := DateTime.Now;
          clientData.PacketsReceived := clientData.PacketsReceived + 1;
          clientData.BytesReceived := clientData.BytesReceived + data.Length;

          roomID := clientData.RoomID;
          if (roomID >= 1) and (roomID <= MAX_ROOMS) then
          begin
            if roomID <> MUTE_ROOM_ID then
            begin
              roomClientsArray := Rooms[roomID].Clients.Keys.ToArray;
              for i := 0 to roomClientsArray.Length - 1 do
              begin
                if roomClientsArray[i] <> key then
                begin
                  try
                    SendPacketToClient(Rooms[roomID].Clients[roomClientsArray[i]].Endpoint, data);
                  except
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    except
      on ex: Exception do
        //LogEvent('ReceiveLoop error: ' + ex.Message);
    end;
  end;
end;


// ПРИЕМ ПАКЕТОВ ЭКРАНА


procedure ScreenReceiveLoop();
var
  remoteEP: IPEndPoint;
  data: array of byte;
  msg: string;
  key: string;
  parts: array of string;
  clientData: ClientInfo;
  roomID: integer;
  i: integer;
  roomClientsArray: array of string;
  username: string;
  keysArr: array of string;
  j: integer;
  targetEndpoint: IPEndPoint;
  targetClient: ClientInfo;
begin
  remoteEP := new IPEndPoint(IPAddress.Any, 0);
  
  LogEvent('SCREEN_SERVER_STARTED on port ' + IntToStr(ScreenPortValue));

  while IsRunning do
  begin
    try
      data := ScreenServer.Receive(remoteEP);
      if (data = nil) or (data.Length = 0) then Continue;

      key := MakeKey(remoteEP);

      if data.Length <= 32768 then
      begin
        try
          msg := System.Text.Encoding.UTF8.GetString(data);

          // ТОЛЬКО ПЕРЕСЫЛКА ВИДЕО-КАДРОВ
          if msg.StartsWith('SCREEN_DATA|') then
          begin
            parts := msg.Split('|');
            if parts.Length >= 6 then
            begin
              username := parts[1];
              
              keysArr := Clients.Keys.ToArray;
              for i := 0 to keysArr.Length - 1 do
              begin
                if Clients.ContainsKey(keysArr[i]) and (Clients[keysArr[i]].Username = username) then
                begin
                  ScreenTotalPacketsReceived := ScreenTotalPacketsReceived + 1;
                  ScreenTotalBytesReceived := ScreenTotalBytesReceived + data.Length;
                  
                  roomID := Clients[keysArr[i]].RoomID;
                  if (roomID >= 1) and (roomID <= MAX_ROOMS) and (roomID <> MUTE_ROOM_ID) then
                  begin
                    roomClientsArray := Rooms[roomID].Clients.Keys.ToArray;
                    for j := 0 to roomClientsArray.Length - 1 do
                    begin
                      if roomClientsArray[j] <> keysArr[i] then
                      begin
                        try
                          targetClient := Rooms[roomID].Clients[roomClientsArray[j]];
                          
                          // НЕ ОТПРАВЛЯЕМ, ЕСЛИ КЛИЕНТ НЕ УКАЗАЛ ПОРТ
                          if targetClient.ScreenPort = 0 then
                          begin
                            // Клиент еще не сообщил порт - пропускаем
                            if ScreenTotalPacketsReceived mod 50 = 0 then
                              LogEvent('SCREEN_DATA: client ' + targetClient.Username + ' has no screen port yet');
                            Continue;
                          end;
                          
                          // Отправляем на порт клиента для экрана
                          targetEndpoint := new IPEndPoint(targetClient.Endpoint.Address, targetClient.ScreenPort);
                          
                          // Отправляем
                          ScreenServer.Send(data, data.Length, targetEndpoint);
                          ScreenTotalPacketsSent := ScreenTotalPacketsSent + 1;
                          ScreenTotalBytesSent := ScreenTotalBytesSent + data.Length;
                          
                          // Логируем каждые 1000 кадров
                          if ScreenTotalPacketsReceived mod 1000 = 0 then
                            LogEvent('SCREEN_DATA forwarded: ' + IntToStr(ScreenTotalPacketsReceived) + ' packets to ' + targetClient.Username);
                        except
                          on ex: Exception do
                          begin
                            if ScreenTotalPacketsReceived mod 500 = 0 then
                              LogEvent('SCREEN_DATA send error to ' + targetClient.Username + ': ' + ex.Message);
                          end;
                        end;
                      end;
                    end;
                  end;
                  Break;
                end;
              end;
            end;
            Continue;
          end;
        except
          on ex: Exception do
            if ScreenTotalPacketsReceived mod 50 = 0 then
              LogEvent('ScreenReceiveLoop parse error: ' + ex.Message);
        end;
      end;
    except
      on ex: Exception do
        if ScreenTotalPacketsReceived mod 50 = 0 then
          //LogEvent('ScreenReceiveLoop receive error: ' + ex.Message);
    end;
  end;
  
  LogEvent('SCREEN_SERVER_STOPPED');
end;

function IsPortAvailable(port: integer): boolean;
var
  testClient: UdpClient;
begin
  Result := true;
  try
    testClient := new UdpClient(port);
    testClient.Close();
  except
    Result := false;
  end;
end;

function TryStartServer(port: integer): boolean;
begin
  Result := false;
  try
    if Server <> nil then
    begin
      try
        Server.Close();
      except
      end;
      Server := nil;
    end;

    Server := new UdpClient(port);
    Server.Client.ReceiveTimeout := 1000;
    ServerPortValue := port;
    Result := true;
  except
  end;
end;

function TryStartScreenServer(port: integer): boolean;
begin
  Result := false;
  try
    if ScreenServer <> nil then
    begin
      try
        ScreenServer.Close();
      except
      end;
      ScreenServer := nil;
    end;

    ScreenServer := new UdpClient(port);
    ScreenServer.Client.ReceiveTimeout := 1000;
    ScreenPortValue := port;
    Result := true;
  except
  end;
end;

procedure ShowBannedIPs();
var
  keysArr: array of string;
  i: integer;
  banData: BanInfoType;
begin
  Console.Clear();
  Writeln('========== BANNED IPS ==========');
  if BannedIPs.Count = 0 then
    Writeln('No banned IPs')
  else
  begin
    keysArr := BannedIPs.Keys.ToArray;
    for i := 0 to keysArr.Length - 1 do
    begin
      banData := BannedIPs[keysArr[i]];
      if DateTime.Now < banData.BanUntil then
        Writeln('IP: ' + keysArr[i] + ' | until: ' + banData.BanUntil.ToString() + ' | reason: ' + banData.Reason)
      else
        BannedIPs.Remove(keysArr[i]);
    end;
  end;
  Writeln;
  Writeln('Press any key to continue...');
  Console.ReadKey(true);
  UpdateStats();
end;

procedure ProcessConsoleCommands();
var
  i: integer;
  keyChar: char;
begin
  while IsRunning do
  begin
    if Console.KeyAvailable then
    begin
      keyChar := Console.ReadKey(true).KeyChar;

      if keyChar = 'q' then
      begin
        IsRunning := false;
        Break;
      end
      else if keyChar = 'c' then
      begin
        for i := 1 to MAX_ROOMS do
          Rooms[i].Clients.Clear();

        Clients.Clear();

        TotalPacketsReceived := 0;
        TotalBytesReceived := 0;
        TotalPacketsSent := 0;
        TotalBytesSent := 0;
        ScreenTotalPacketsReceived := 0;
        ScreenTotalBytesReceived := 0;
        ScreenTotalPacketsSent := 0;
        ScreenTotalBytesSent := 0;

        UpdateStats();
      end
      else if keyChar = 'b' then
      begin
        ShowBannedIPs();
      end;
    end;

    Thread.Sleep(100);
  end;
end;

procedure RunServer();
var
  port: integer;
  attempt: integer;
begin
  Console.Title := 'Voice Chat Server';

  LogSync := new object();
  EnsureLogDirectoryExists();
  EnsureDirectoryExists();
  EnsureChatDirectoryExists();

  // Запуск голосового сервера
  port := SERVER_PORT;
  for attempt := 0 to 9 do
  begin
    if IsPortAvailable(port + attempt) and TryStartServer(port + attempt) then
      Break;
  end;

  if Server = nil then
  begin
    LogEvent('SERVER_START_FAILED');
    Writeln('Cannot start voice server');
    Readln();
    Exit;
  end;

  // Запуск сервера для экранов
  port := SCREEN_PORT;
  for attempt := 0 to 9 do
  begin
    if IsPortAvailable(port + attempt) and TryStartScreenServer(port + attempt) then
      Break;
  end;

  if ScreenServer = nil then
  begin
    LogEvent('SCREEN_SERVER_START_FAILED');
    Writeln('Cannot start screen server');
    Readln();
    Exit;
  end;

  LogEvent('SERVER_START voice_port=' + IntToStr(ServerPortValue) + ' screen_port=' + IntToStr(ScreenPortValue));

  LoadUsers();
  InitRooms();

  Clients := new Dictionary<string, ClientInfo>;

  TotalPacketsReceived := 0;
  TotalBytesReceived := 0;
  TotalPacketsSent := 0;
  TotalBytesSent := 0;
  ScreenTotalPacketsReceived := 0;
  ScreenTotalBytesReceived := 0;
  ScreenTotalPacketsSent := 0;
  ScreenTotalBytesSent := 0;

  IsRunning := true;
  IsDiscovering := true;

  RecvThread := new Thread(ReceiveLoop);
  RecvThread.IsBackground := true;
  RecvThread.Start();

  ScreenRecvThread := new Thread(ScreenReceiveLoop);
  ScreenRecvThread.IsBackground := true;
  ScreenRecvThread.Start();

  DiscoveryThread := new Thread(DiscoveryResponseLoop);
  DiscoveryThread.IsBackground := true;
  DiscoveryThread.Start();

  HeartbeatThread := new Thread(HeartbeatLoop);
  HeartbeatThread.IsBackground := true;
  HeartbeatThread.Start();

  StatsLogThread := new Thread(StatsLogLoop);
  StatsLogThread.IsBackground := true;
  StatsLogThread.Start();

  UpdateStats();
  ProcessConsoleCommands();

  IsRunning := false;
  IsDiscovering := false;

  try if RecvThread <> nil then RecvThread.Join(500); except end;
  try if ScreenRecvThread <> nil then ScreenRecvThread.Join(500); except end;
  try if DiscoveryThread <> nil then DiscoveryThread.Join(500); except end;
  try if HeartbeatThread <> nil then HeartbeatThread.Join(500); except end;
  try if StatsLogThread <> nil then StatsLogThread.Join(500); except end;

  LogStatsSnapshot();
  LogEvent('SERVER_STOP voice_port=' + IntToStr(ServerPortValue) + ' screen_port=' + IntToStr(ScreenPortValue));

  SaveUsers();

  try
    if Server <> nil then
      Server.Close();
  except
  end;

  try
    if ScreenServer <> nil then
      ScreenServer.Close();
  except
  end;
end;

begin
  try
    RunServer();
  except
    on ex: Exception do
    begin
      try
        LogEvent('SERVER_CRASH message=' + ex.Message);
      except
      end;
      Writeln(ex.Message);
    end;
  end;
end.