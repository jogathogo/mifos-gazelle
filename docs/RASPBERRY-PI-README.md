
# How to boot up Ubuntu Server on Raspberry PI 5 (Headless)

## Requirements
1. Buy one Raspberry PI. Raspberry PI 5 - 16GB RAM. It does not work on RPI-8GB.
2. Buy one memory card - 16GB at least
3. A memory card reader
4. A microHDMI cable if you want to see the logs, OR you're going to boot up an OS with UI.
- In our case, we're going to boot up an Ubuntu server and then we will SSH into the server. So, no such requirement for a microHDMI cable.

## Writing SD card.
1. On your PC, install Raspberry Pi Imager. Here, download for your machine
<img width="800" height="412" alt="image" src="https://github.com/user-attachments/assets/d94b689c-16a5-40bd-a2e6-92d28501410e" />

2. Now, click on Next \
   This pop-up will come.
Note: I have already configured my sd-card that's why I am seeing all the options.

<img width="800" height="412" alt="image" src="https://github.com/user-attachments/assets/be7f9adb-e762-4396-a0c4-2161cd7c3025" />


3. For the first time, you'll see something like this.

OR if you click on `No, Clear Settings` and then again click on next, you'll see something like this.

<img width="800" height="408" alt="image" src="https://github.com/user-attachments/assets/80c50d42-31bc-4423-8ebf-13a8981c96f8" />


4. Click on Edit Settings. NOTE: REMEMBER HOSTNAME, USERNAME AND PASSWORD. This will be useful when we SSH.

By Default, you'll see this.

<img width="1919" height="1079" alt="Screenshot 2025-08-14 142220" src="https://github.com/user-attachments/assets/3f1bff4b-9a6f-45cd-9873-e9f8502809aa" />

<img width="1919" height="1079" alt="Screenshot 2025-08-14 142240" src="https://github.com/user-attachments/assets/3640cbcb-3d09-4085-a150-4eb8f021719d" />


5. Here, you've to

- Enable Set hostname
- Enable set username and password
- Enable Configure wireless LAN. It will fill in the details of the wifi network you're connected to. \
- Select "IN" for Wireless LAN country. If you're in India. \
  ### **Here, I have selected 'US'. I was not able to connect to the 5GHz network of my router.**
- and select the *locale settings * accordingly. I have kept it Asia/kolkata
- Keyboard Layout: "us"

<img width="1910" height="1079" alt="Screenshot 2025-08-14 142121" src="https://github.com/user-attachments/assets/c0d84cec-b9e1-4a97-a4af-812d632fdc0b" />

6. Now in SERVICES
Enable SSH and "Use password authentication" \
Like this,

<img width="1919" height="1079" alt="Screenshot 2025-08-14 142315" src="https://github.com/user-attachments/assets/45e33592-1fc8-457c-a44e-5cd5419560c0" />

SAVE
YES

7. Let it erase your data. Consider taking a backup if your SD card contains some important info

- Let it write, verify and finally flash your SD card.

- It will automatically eject your card from your laptop/system.

- Insert the SD card in Raspberry PI 5.

- Start the Raspberry PI 5. It will automatically connect with your Wifi, do the login and a few other things.

- If you're not using an HDMI cable and not seeing the logs.

- and if you're seeing the green light is blinking. It's a good signal

- You'll be able to SSH to it.

8. To verify you can, use the command 'ping raspberry.local', you'll get output something like this,

```bash
$ ping raspberrypi.local

Pinging raspberrypi.local [fe80::8aa2:9eff:fe04:381c%15] with 32 bytes of data:
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 
Reply from fe80::8aa2:9eff:fe04:381c%15: time=4ms 

Ping statistics for fe80::8aa2:9eff:fe04:381c%15:
    Packets: Sent = 4, Received = 4, Lost = 0 (0% loss),
Approximate round-trip times in milliseconds:
    Minimum = 4ms, Maximum = 4ms, Average = 4ms

```

OR you can log in to your router portal and see the IP address to log in

<img width="957" height="83" alt="Screenshot 2025-08-14 143024" src="https://github.com/user-attachments/assets/9295e52f-14fd-4955-9535-bd33b5970058" />

9. Moment of Truth. SSH.
`ssh <username>@<ip-addr>`

```bash
$ ssh devarshrpi@192.168.1.94
devarshrpi@192.168.1.94's password: 
Welcome to Ubuntu 24.04.2 LTS (GNU/Linux 6.8.0-1018-raspi aarch64)
.
.
.
.
.
.
Last login: Sat Jul 19 14:14:19 2025 from 192.168.1.65
```
