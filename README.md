# Buzzer

A real-time voice communication system with room-based audio streaming, screen sharing, noise suppression, and chat functionality. Built with PascalABC.NET 3.10.3 using UDP protocol for low-latency voice transmission.

## Features

### Voice Communication
- Real-time voice streaming with UDP (low latency)
- Room-based audio routing (11 rooms including "Mute")
- Spectral noise suppression with adaptive learning
- Automatic noise profile generation
- Volume control

### Screen Sharing (New!)
- Real-time screen capture and streaming
- Selective viewing of other users' screens
- Automatic port negotiation for screen data
- Room-based screen sharing (visible only to users in the same voice room)
- User presence indicator (● shows who is sharing)
- PNG-based frame transmission with chunking for UDP delivery
- Frame reassembly with timeout handling
- Preview in main window

### Chat System
- Global chat across all rooms
- Room-specific chat channels
- Chat history persistence (saved to files)
- Base64-encoded message transmission
- Anti-flood protection (cooldown and rate limiting)
- Chat message limits (500KB per hour per user)

### Authentication
- User registration and login
- Password-protected accounts
- User session management
- Last login tracking
- Duplicate login prevention (same user cannot log in twice)
- User bans (IP and username-based)
- Login attempt limiting (5 attempts, 1-hour ban)
- Rate limiting for registrations (3 per IP per hour)
- Username validation (Latin letters, numbers, underscores only, no Cyrillic, no spaces, not only digits)

### Monitoring and Statistics
- Real-time server statistics
- Per-user traffic monitoring (packets/bytes)
- Logging system with event and stats logs
- Console commands: `q` (quit), `c` (clear clients), `b` (show banned IPs)

### Audio Processing
- Noise gate with adjustable threshold (recommended: 0)
- FFT-based spectral analysis
- Spectral subtraction noise suppression
- Overlap-add processing for smooth audio
- Monitor mode (hear yourself)

### Network Features
- Automatic server discovery via UDP broadcast
- Manual server IP connection
- Heartbeat mechanism (15-second timeout)
- Client disconnection detection
- Room switching without reconnection

### System Tray Support
- Minimize to system tray
- Tray icon with context menu
- Background operation

### Planned Features
- ~~Screen sharing for room participants~~ (DONE)
- ~~Security hardening against common vulnerabilities~~ (PARTIALLY DONE)
- Bug fixes and stability improvements
- Voice activity detection (VAD)

## System Requirements

### Server
- Windows 11 (guaranteed)
- Windows 10/8/7 (may work but not guaranteed)
- PascalABC.NET 3.10.3
- UDP ports: 12345 (voice), 12346 (discovery), 12347 (screen sharing)
- File system permissions for log and chat directories

### Client
- Windows 11 (guaranteed)
- Windows 10/8/7 (may work but not guaranteed)
- PascalABC.NET 3.10.3
- NAudio.dll for audio capture/playback
- Audio input device (microphone)
- Audio output device (speakers/headphones)
- sound.mp3 file for @all notifications (optional)

## Installation

### Server Setup
1. Open Server3.pas in PascalABC.NET 3.10.3
2. Click Run or press F9 to compile and execute
3. Server will start automatically

### Client Setup
1. Open Client.pas in PascalABC.NET 3.10.3
2. Ensure NAudio.dll is in the same directory as Client.pas
3. Place sound.mp3 in client directory (optional, for @all sound)
4. Click Run or press F9 to launch

## Usage

### Starting the Server
1. Run Server3.pas in PascalABC.NET
2. Server will try ports 12347-12354 (auto-fallback)
3. Creates necessary directories (`logs/`, `chat/`, `passw/`)
4. Starts listening for clients
5. Console interface displays statistics

### Client Connection
1. Launch client application in PascalABC.NET
2. Click SCAN to find servers on your local network
3. Select a server from the list or enter IP address manually
4. Click CONNECT
5. Register a new account or login with existing credentials
6. Choose a room (1-10 for voice, 11 for mute) and start talking

### Screen Sharing
1. Connect to a server
2. Click CAPTURE to start sharing your screen
3. Your screen will appear in the center panel
4. Other users in your room can view your screen
5. Click STOP to end sharing
6. To view another user's screen:
   - Double-click their name in the user list
   - Or select them and click VIEW
7. Active screen sharers are marked with ● in the user list

### Audio Settings
Click AUDIO button to adjust:
- Microphone volume (0-100%)
- Speaker volume (0-100%)
- Noise gate threshold (recommended: 0)
- Real-time frequency spectrum visualization

## Configuration

### Server Constants (Server3.pas)
```pascal
SERVER_PORT = 12345;        // Voice port
DISCOVERY_PORT = 12346;     // Discovery port
SCREEN_PORT = 12347;        // Screen sharing port
MAX_ROOMS = 11;             // Number of rooms (room 11 = Mute)
HEARTBEAT_TIMEOUT = 15000;  // Client timeout in milliseconds
MAX_LOGIN_ATTEMPTS = 5;     // Failed login attempts before ban
BAN_DURATION_HOURS = 1;     // Ban duration in hours
CHAT_COOLDOWN_MS = 500;     // Minimum time between chat messages
MESSAGE_LIMIT_PER_HOUR = 500000; // Chat message limit (characters)
MAX_REGISTRATIONS_PER_HOUR = 3; // Registrations per IP per hour
```

## Protocol

### Voice Packets
- Audio format: 16-bit PCM, 44100 Hz, Mono
- Packet size: Variable (up to 32KB)
- Codec: Raw PCM

### Control Messages
```
LOGIN|username|password                - Login request (client to server)
REGISTER|username|password             - Registration request (client to server)
ROOM_CHANGE|roomID                     - Room change request (client to server)
CHAT_GLOBAL|text                       - Global chat message (client to server)
CHAT_ROOM|roomID|text                  - Room chat message (client to server)
PING                                   - Heartbeat request (server to client)
PONG                                   - Heartbeat response (client to server)
USER_LIST|user1,user2                  - Room user list (server to client)
AUTH_SUCCESS|username                  - Authentication success (server to client)
AUTH_FAIL|message                      - Authentication failure (server to client)
```

### Screen Sharing Messages
```
SCREEN_START|username|port             - Start screen sharing (client to server/voice)
SCREEN_STOP|username                   - Stop screen sharing (client to server/voice)
SCREEN_VIEW|username|port              - Request screen view (client to server/voice)
SCREEN_DATA|username|frame|total|idx|data - Screen frame data (client->server->client)
```

## Architecture

### Client (Windows)
- MainForm (UI)
- Audio Pipeline
  - WaveIn (microphone capture)
  - Noise Suppression (FFT-based spectral subtraction)
  - Gain Control
  - WaveOut (speaker playback)
  - Monitor Mode (hear own voice)
- Screen Sharing Pipeline (New!)
  - Screen capture (GDI+)
  - PNG encoding
  - Frame chunking
  - UDP transmission
  - Frame reassembly
  - Preview display
- Network Layer
  - UDP Voice Socket
  - UDP Screen Socket
  - Heartbeat
  - Server Discovery
- Chat System
  - Global Chat
  - Room Chat
- User Interface
  - Room buttons (11 rooms)
  - User list with status indicators
  - Chat panels
  - Audio settings dialog
  - Spectrum visualization
  - Screen view panel

### Server (Windows)
- UDP Server (voice)
- UDP Server (screen sharing) (New!)
- Discovery Server (broadcast response)
- Client Manager
- Authentication (login/register)
- Security System (New!)
  - IP banning
  - Login attempt tracking
  - Rate limiting
  - Input validation
- Room Management
- Statistics tracking
- Logging System
  - Event Log (server_events.log)
  - Stats Log (1-minute intervals, server_stats.log)
- Chat Persistence
  - Global History (global_chat.txt)
  - Room History (room_*.txt)
- Heartbeat Monitor (15-second timeout)
- Console Commands: q, c, b

## Development

### Requirements
- PascalABC.NET 3.10.3 (maybe exact version)
- NAudio.dll (included or downloaded from GitHub)
- Windows 11 (guaranteed, other versions may work)

### Dependencies
- NAudio - Audio capture and playback library
- PascalABC.NET 3.10.3 - Pascal compiler and IDE (http://pascalabc.net/)

## Troubleshooting

### Client cannot find server
- Ensure server is running
- Check if both are on the same network (including VPN)
- Disable Windows firewall temporarily for testing
- Use manual IP connection if scan fails

### No audio input/output
- Check microphone and speaker connections
- Verify audio devices are enabled in Windows
- NAudio.dll must be in the same directory
- Check audio settings in the client

### Noise suppression not working
- Set threshold to 0 (recommended value)
- Allow 2-3 seconds for noise profile learning
- Speak after profile is built (indicator shows "PROFILE READY")

### Screen sharing not working
- Ensure server is using SCREEN_PORT (12347)
- Check firewall for UDP port 12347
- Both clients must be in the same voice room
- Viewing client must be connected to the server

## Known Limitations and Security

### Current State
- No administration capabilities (this is by design and will not be added)
- No encryption (suitable for local networks only)
- Raw PCM audio (larger bandwidth than compressed codecs)
- No voice activity detection in transmission (sends continuously)
- Single-threaded UI may lag under heavy load
- Uses Windows-specific audio APIs

### Security Hardening (Implemented)
- IP-based banning with duration
- Login attempt limiting (5 attempts, 1-hour ban)
- Duplicate login prevention
- Rate limiting for registrations (3 per IP per hour)
- Input validation for usernames (no Cyrillic, no spaces, Latin only)
- Chat anti-flood (500ms cooldown)
- Chat message limits (500KB per hour)
- Proper buffer handling in FFT operations
- Input sanitization for chat messages

## License
This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing
1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## Support
For issues or questions:
- Open an issue on GitHub
- Note: This is a learning/educational project. It is not intended for production use without proper security review and hardening.

---

**Give up hope, everyone who enters here**
