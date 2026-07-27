- Buzzer

A real-time voice communication system with room-based audio streaming, noise suppression, and chat functionality. Built with PascalABC.NET 3.10.3 using UDP protocol for low-latency voice transmission.

-- Features

Voice Communication
- Real-time voice streaming with UDP (low latency)
- Room-based audio routing (11 rooms including "Mute")
- Spectral noise suppression with adaptive learning
- Automatic noise profile generation
- Volume control with boost option
- 16-band frequency spectrum visualization
- Voice activity detection (VAD)

Chat System
- Global chat across all rooms
- Room-specific chat channels
- Chat history persistence (saved to files)
- @all mention with sound notification
- Base64-encoded message transmission

Authentication
- User registration and login
- Password-protected accounts
- User session management
- Last login tracking

Monitoring and Statistics
- Real-time server statistics
- Per-user traffic monitoring (packets/bytes)
- Logging system with event and stats logs
- Console commands:
  - q - Quit server
  - c - Clear all clients

Audio Processing
- Noise gate with adjustable threshold (recommended: 0)
- FFT-based spectral analysis
- Spectral subtraction noise suppression
- Overlap-add processing for smooth audio
- Real-time EQ visualization
- Monitor mode (hear yourself)
- Boost option for microphone/speaker

Network Features
- Automatic server discovery via UDP broadcast
- Manual server IP connection
- Heartbeat mechanism (15-second timeout)
- Client disconnection detection
- Room switching without reconnection

-- Planned Features

- Screen sharing for room participants
- Bug fixes and stability improvements
- Security hardening against common vulnerabilities

-- System Requirements

Server
- Windows 11 (guaranteed)
- Windows 10/8/7 (may work but not guaranteed)
- PascalABC.NET 3.10.3
- UDP ports: 12345 (voice), 12346 (discovery)
- File system permissions for log and chat directories

Client
- Windows 11 (guaranteed)
- Windows 10/8/7 (may work but not guaranteed)
- PascalABC.NET 3.10.3
- NAudio library for audio capture/playback
- Audio input device (microphone)
- Audio output device (speakers/headphones)
- sound.mp3 file for @all notifications (optional)

-- Installation

Server Setup
1. Open Server3.pas in PascalABC.NET 3.10.3
2. Click Run or press F9 to compile and execute
3. Server will start automatically

Client Setup
1. Open Client.pas in PascalABC.NET 3.10.3
2. Ensure NAudio.dll is in the same directory as Client.pas
3. Place sound.mp3 in client directory (optional, for @all sound)
4. Click Run or press F9 to launch

-- Usage

Starting the Server

1. Run Server3.pas in PascalABC.NET
2. Server will try ports 12345-12354 (auto-fallback)
3. Creates necessary directories (logs/, chat/, passw/)
4. Starts listening for clients
5. Console interface displays statistics


Client Connection
1. Launch client application in PascalABC.NET
2. Click SCAN to find servers on your local network
3. Select a server from the list or enter IP address manually
4. Click CONNECT
5. Register a new account or login with existing credentials
6. Choose a room (1-10 for voice, 11 for mute) and start talking


-- Configuration

Server Constants (Server3.pas)
SERVER_PORT = 12345;        // Voice port
DISCOVERY_PORT = 12346;     // Discovery port
MAX_ROOMS = 11;             // Number of rooms (room 11 = Mute)
HEARTBEAT_TIMEOUT = 15000;  // Client timeout in milliseconds

Audio Settings
Access AUDIO button in client for:
- Microphone volume (0-100%)
- Speaker volume (0-100%)
- Noise gate threshold (recommended: 0)
- Boost toggle for microphone/speaker


-- Protocol

Voice Packets
- Audio format: 16-bit PCM, 44100 Hz, Mono
- Packet size: Variable (up to 32KB)
- Codec: Raw PCM

Control Messages
- LOGIN|username|password - Login request (client to server)
- REGISTER|username|password - Registration request (client to server)
- ROOM_CHANGE|roomID - Room change request (client to server)
- CHAT_GLOBAL|text - Global chat message (client to server)
- CHAT_ROOM|roomID|text - Room chat message (client to server)
- PING - Heartbeat request (server to client)
- PONG - Heartbeat response (client to server)
- USER_LIST|user1,user2 - Room user list (server to client)
- AUTH_SUCCESS|username - Authentication success (server to client)
- AUTH_FAIL|message - Authentication failure (server to client)

-- Architecture

Client (Windows)
  - MainForm (UI)
  - Audio Pipeline
    - WaveIn (microphone capture)
    - Noise Suppression (FFT-based spectral subtraction)
    - Gain Control
    - WaveOut (speaker playback)
    - Monitor Mode (hear own voice)
  - Network Layer
    - UDP Voice Socket
    - Heartbeat
    - Server Discovery
  - Chat System
    - Global Chat
    - Room Chat
  - User Interface
    - Room buttons (11 rooms)
    - User list
    - Chat panels
    - Audio settings dialog
    - Spectrum visualization


Server (Windows)
  - UDP Server (voice)
  - Discovery Server (broadcast response)
  - Client Manager
    - Authentication (login/register)
    - Room Management
    - Statistics tracking
  - Logging System
    - Event Log (server_events.log)
    - Stats Log (1-minute intervals, server_stats.log)
  - Chat Persistence
    - Global History (global_chat.txt)
    - Room History (room_*.txt)
  - Heartbeat Monitor (15-second timeout)
  - Console Commands
    - q - Quit server
    - c - Clear all clients

 
-- File Structure
buzzer/
├── Server/
│   ├── Server3.pas          // Main server code
│   ├── passw/
│   │   └── users.txt        // User database (username|password|created|lastlogin|lastip)
│   ├── logs/
│   │   ├── server_events.log
│   │   └── server_stats.log
│   └── chat/
│       ├── global_chat.txt
│       └── room_*.txt       // Room chat history
├── Client/
│   ├── Client.pas           // Main client code
│   ├── NAudio.dll           // Audio library
│   └── sound.mp3            // Notification sound for @all mentions
└── README.md


-- Development
{

Requirements
- PascalABC.NET 3.10.3 (maybe exact version)
- NAudio.dll (included or downloaded from GitHub)
- Windows 11 (guaranteed, other versions may work)

Building
1. Open PascalABC.NET 3.10.3
2. Open Server3.pas for server build
3. Open Client.pas for client build
4. Press F9 or click Run button
5. Executable will be generated in the output directory

Dependencies
- NAudio - Audio capture and playback library (https://github.com/naudio/NAudio)
- PascalABC.NET 3.10.3 - Pascal compiler and IDE (http://pascalabc.net/)

}


-- Troubleshooting
{

Common Issues
Server fails to start on port 12345
- Check if another application is using the port
- Server automatically tries ports 12345-12354
- Firewall may block the application
Client cannot find server
- Ensure server is running
- Check if both are on the same network
- Disable Windows firewall temporarily for testing
- Use manual IP connection if scan fails
No audio input/output
- Check microphone and speaker connections
- Verify audio devices are enabled in Windows
- NAudio.dll must be in the same directory
- Check audio settings in the client
Noise suppression not working
- Set threshold to 0 (recommended value)
- Allow 2-3 seconds for noise profile learning
- Speak after profile is built (indicator shows "PROFILE READY")

}

--Known Limitations and Security
{

Current State
- No administration capabilities (this is by design and will not be added)
- No encryption (suitable for local networks only)
- Raw PCM audio (larger bandwidth than compressed codecs)
- No voice activity detection in transmission (sends continuously)
- Single-threaded UI may lag under heavy load
- Windows 11 only (guaranteed to work)
- Uses Windows-specific audio APIs
Security Hardening (Planned)
- Protection against common UDP-based attacks
- Input validation and sanitization
- Buffer overflow protection
- Rate limiting for control messages
- Authentication token security improvements

}

-- License
This project is licensed under the MIT License - see the LICENSE file for details.

-- Contributing
1. Fork the repository
2. Create your feature branch (git checkout -b feature/AmazingFeature)
3. Commit your changes (git commit -m 'Add some AmazingFeature')
4. Push to the branch (git push origin feature/AmazingFeature)
5. Open a Pull Request

-- Support
For issues or questions:
- Open an issue on GitHub

Note: This is a learning/educational project. It is not intended for production use without proper security review and hardening.



Give up hope, everyone who enters here
