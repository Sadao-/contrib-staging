.386 
.model flat,stdcall 
option casemap:none
OPTION SCOPED 
include template.inc 


WM_SHELLNOTIFY equ WM_USER+5 
IDI_TRAY equ 0 
IDM_RESTORE equ 1000
IDM_STARTSTOP equ 1001
IDM_FREQUEST equ 1003
IDM_GATEWAY equ 1004 
IDM_CONFIGURE equ 1005
IDM_SHOWLOG equ 1006
IDM_EXIT equ 1010
ID_CLEARLOG equ 102
ID_CLOSE equ 8
IDFLOG equ 101
ID_KEY equ 104 
;----------------------------------------
;Prototypes (some more in template.inc)
ExitFserve PROTO
;----------------------------------------
;Macros
  ;This allows to embed Strings directly into local function code;
  szText MACRO Name, Text:VARARG 
         LOCAL lbl 
          jmp lbl 
            Name db Text,0 
          lbl: 
  ENDM 
;----------------------------------------
;DATA segment
.data 
ClassName  db "TrayIconFreenetClass",0 
AppName    db "Freenet",0
fserve     db " -cp freenet.jar Freenet.node.Node",0
fconfig    db " -cp freenet.jar Freenet.node.gui.Config freenet.ini",0
gatewayURIdef db "http://127.0.0.1:",0      ; Initialization will use this to creat gatewayURI
finifile db "./freenet.ini",0


RestoreString db "&Restore",0 
StopString db "&Stop Freenet",0
StartString db "&Start Freenet",0
GatewayString db "Open &Gateway",0
FrequestString db "&Request Key",0
ShowlogString db "Show Log",0 
ConfigureString db "&Configure",0 
ExitString   db "E&xit",0
errMsg db "Couldn't start the node,",13,"make sure FLaunch.ini has an entry javaw= pointing to javaw.exe or",13,"an entry Javaexec= pointing to a Java Runtime binary (jview.exe/java.exe)",0
errTitle db "Error starting node",0 
MAXLEN equ 256
javawpath db "java.exe",0, MAXLEN-9 DUP (?) ; Stores the path to javaw (incl filename)
fRunning db 0       ;indicates whether the Node is running

.data?
BUFLEN equ 400
buffer      db BUFLEN DUP (?)   ; general buffer for string manipulation
GATEWLEN equ 90
gatewayURI  db GATEWLEN  DUP (?)     ; The complete GatewayURI is copied here
execbuf db BUFLEN+GATEWLEN-1 DUP (?) ;Buffer to be executed to fetch key

hfserveThrd dd ?                ; Used to save the threadhandle of fserve 
hfservePrc  dd ?                ; Used to save the processhandle of fserve
hInstance dd ?
note NOTIFYICONDATA <> 
hPopupMenu dd ? 
;----------------------------------------------------------------------------------------
.code 
start: 
    invoke GetModuleHandle, NULL 
    mov    hInstance,eax 
    invoke WinMain, hInstance,NULL,NULL, SW_SHOWDEFAULT
    invoke ExitProcess,eax 
; ########################################################################

szCatStr proc lpszSource:DWORD, lpszAdd:DWORD

    LOCAL ln1:DWORD

    invoke StrLen,lpszSource
    mov ln1, eax

    mov esi, lpszAdd
    mov edi, lpszSource
    add edi, ln1

  @@:
    mov al, [esi]
    inc esi
    mov [edi], al
    inc edi
    test al, al       ; test for zero
    jne @B

    ret

szCatStr endp

; ########################################################################
;����������������������������������������������������������������������������
OnlyOneInstance	PROC	STDCALL

LOCAL	hSemaphore:HANDLE
LOCAL hMainWnd:HWND

	invoke CreateSemaphore, NULL, 0, 1, ADDR ClassName
	mov    hSemaphore,eax

	invoke	GetLastError
	.IF (eax == ERROR_ALREADY_EXISTS)
		invoke	CloseHandle, hSemaphore
      .ELSEIF (eax == ERROR_SUCCESS)    ; created Semaphore will
		mov	eax, TRUE             ; prevent other instances
		ret                         ; return TRUE to continue
	.ENDIF

;commenting out, we don't want to show the main window as it is invisible.
;	invoke FindWindow, ADDR ClassName, NULL
;	cmp    eax,0                      ; didn't find Window? Then
;      jz ReturnZero                     ; return FALSE (eax=0) to exit
;
;	invoke GetLastActivePopup, eax
;	mov	hMainWnd, eax		; eax == hMainWnd or hPopupWnd
;
;   invoke	IsIconic, hMainWnd
;    .IF (eax)
;		invoke	ShowWindow, hMainWnd, SW_RESTORE
;		jmp	ReturnZero	      ; return FALSE (eax=0) to exit
;   .ENDIF
;   invoke	SetForegroundWindow, hMainWnd

ReturnZero: mov eax,FALSE		; return FALSE (eax=0) to exit
    ret

OnlyOneInstance endp
;��������������������������������������������������������������������������
;----------------------------------------------------------------------------------------
Initialize proc
      ;==================================================
      ; Initialize (e.g. Read Javabin path
      ;==================================================
 szText flsec,"Freenet Launcher"
 szText javakey,"Javaexec"
 szText javawkey,"Javaw"
 szText fprxkey,"services.fproxy.port"
 szText flfile,"./FLaunch.ini"
 szText finisec,"Freenet node"
 szText empty, 0


 ; Set current directory to the dir where the exe is in
 invoke GetModuleFileName, NULL, OFFSET buffer, BUFLEN     ;Get complete path of the executable
 mov esi,eax           ;put amount of characters in si, stripping the filename next
 @@:
  cmp esi, 0           ;when at begin of string quit
  jz @F
  dec esi
  lea ebx, [OFFSET buffer + esi]
  mov ah, [ebx]
  cmp ah, 92          ; if not \, continue
  jnz @B
  @@:
  mov [OFFSET buffer + esi], 0
 invoke SetCurrentDirectory, addr buffer                     ;Set current dir to this path

 ;Get the Jawaw executable
 invoke GetPrivateProfileString, OFFSET flsec,OFFSET javawkey, OFFSET empty, OFFSET javawpath, MAXLEN, OFFSET flfile
 cmp eax,0                  ; Could I read javaw entry?
 jnz @F                     ; Otherwise read Javaexec entry
 invoke GetPrivateProfileString, OFFSET flsec,OFFSET javakey, OFFSET empty, OFFSET javawpath, MAXLEN, OFFSET flfile
 @@:
 ;Get the listenport of FProxy
 invoke GetPrivateProfileString, OFFSET finisec,OFFSET fprxkey, OFFSET empty, OFFSET buffer, 6, OFFSET finifile
 mov    gatewayURI , 0  ;resetting the gatewayURI string
 invoke szCatStr, addr gatewayURI, addr gatewayURIdef   ; copying the /127.0.0.1:
 invoke szCatStr, addr gatewayURI, addr buffer          ; and the port into gatewayURI
 ;debug only: invoke WritePrivateProfileString, OFFSET finisec,OFFSET fprxkey, OFFSET gatewayURI, OFFSET flfile


 ret
Initialize endp
;----------------------------------------------------------------------------------------
StartFserve proc
        ;==================================================
        ; Start FServe
        ;==================================================
LOCAL prcInfo:PROCESS_INFORMATION
LOCAL StartInfo:STARTUPINFO


    mov   StartInfo.cb,SIZEOF STARTUPINFO
    mov   StartInfo.lpReserved,NULL
    mov   StartInfo.lpDesktop,NULL
    mov   StartInfo.lpTitle,NULL
    mov   StartInfo.dwFlags,STARTF_USESHOWWINDOW
    mov   StartInfo.wShowWindow,SW_HIDE
    mov   StartInfo.cbReserved2,0
    mov   StartInfo.lpReserved2,NULL
    invoke CreateProcess, addr javawpath, addr fserve, NULL, NULL, FALSE, NORMAL_PRIORITY_CLASS, NULL, NULL,\
        ADDR StartInfo, ADDR prcInfo    ; start FServe
    .if (eax)                 ; CreateProcess returns nonzero on succes
       mov fRunning,1         ; set fRunning flag
    .elseif                    
       invoke MessageBox, NULL, addr errMsg, addr errTitle, MB_OK+MB_ICONERROR+MB_TASKMODAL   
    .endif
    mov ecx, prcInfo.hProcess  ; Save Processhandle of Fserve in global variable
    mov hfservePrc, ecx
    mov ecx, prcInfo.hThread   ; Save Threadhandle of Fserve in global variable
    mov hfserveThrd, ecx
    ret
StartFserve Endp    


;----------------------------------------------------------------------------------------
WinMain proc hInst:HINSTANCE,hPrevInst:HINSTANCE,CmdLine:LPSTR,CmdShow:DWORD 
    LOCAL wc:WNDCLASSEX 
    LOCAL msg:MSG 
    LOCAL hwnd:HWND

    call OnlyOneInstance        ; make sure we have only one instance running
    cmp eax,FALSE               ; and if it is already running
    jz EndWinMain               ; exit at once
    call Initialize             ; Call the initialize procedure to read the prefs and set the CWD
        
        ;==================================================
        ; Fill WNDCLASSEX structure with required variables
        ;==================================================
    mov   wc.cbSize,SIZEOF WNDCLASSEX 
    mov   wc.style, CS_HREDRAW or CS_VREDRAW or CS_DBLCLKS 
    mov   wc.lpfnWndProc, OFFSET WndProc 
    mov   wc.cbClsExtra,NULL 
    mov   wc.cbWndExtra,NULL 
    push  hInst 
    pop   wc.hInstance 
    mov   wc.hbrBackground,COLOR_APPWORKSPACE 
    mov   wc.lpszMenuName,NULL 
    mov   wc.lpszClassName,OFFSET ClassName 
    invoke LoadIcon,NULL,IDI_APPLICATION 
    mov   wc.hIcon,eax 
    mov   wc.hIconSm,eax 
    invoke LoadCursor,NULL,IDC_ARROW 
    mov   wc.hCursor,eax 
    invoke RegisterClassEx, addr wc 
    invoke CreateWindowEx,WS_EX_CLIENTEDGE,ADDR ClassName,ADDR AppName,\ 
       WS_OVERLAPPED+WS_CAPTION+WS_SYSMENU+WS_MINIMIZEBOX+WS_MAXIMIZEBOX+WS_VISIBLE+WS_MINIMIZE,CW_USEDEFAULT,\
       CW_USEDEFAULT,350,200,NULL,NULL,hInst,NULL 
    mov   hwnd,eax

      ;===================================
      ; Loop until PostQuitMessage is sent
      ;===================================
    .while TRUE 
        invoke GetMessage, ADDR msg,NULL,0,0 
        .BREAK .IF (!eax)       ;break if there is no new message
        invoke TranslateMessage, ADDR msg 
        invoke DispatchMessage, ADDR msg 
    .endw 
    mov eax,msg.wParam 
  EndWinMain:
    ret 
WinMain endp 

;----------------------------------------------------------------------------------------------
ExitFserve proc
      invoke TerminateProcess, hfservePrc, 0    ; brutal closing of the node
      cmp ax,0                                  ; returns nonzero on success
      jz @F
      mov   fRunning, 0                         ; reset fRunning flag, if successful
      @@:
      invoke CloseHandle, hfserveThrd           ; and closing the handles of the process
      invoke CloseHandle, hfservePrc
      ret
ExitFserve endp
;----------------------------------------------------------------------------------------------
WndProc proc hWnd:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM 
    LOCAL pt:POINT
    LOCAL StartInfo:STARTUPINFO         ; needed to start the configuration process, outsource when outsourcing this one
    LOCAL prcInfo:PROCESS_INFORMATION   ;   "               "
    LOCAL lpmenitinf:MENUITEMINFO
 
    .if uMsg==WM_CREATE
        invoke CreatePopupMenu 
        mov hPopupMenu,eax 
        ;invoke AppendMenu,hPopupMenu,MF_STRING,IDM_RESTORE,addr RestoreString
        invoke AppendMenu,hPopupMenu,MF_STRING+MF_GRAYED,IDM_GATEWAY,addr GatewayString
        ;invoke AppendMenu,hPopupMenu,MF_STRING,IDM_FREQUEST,addr FrequestString
        invoke AppendMenu,hPopupMenu,MF_STRING,IDM_STARTSTOP,addr StartString
        invoke AppendMenu,hPopupMenu,MF_STRING,IDM_CONFIGURE,addr ConfigureString
;        invoke AppendMenu,hPopupMenu,MF_STRING,IDM_SHOWLOG,addr ShowlogString
        invoke AppendMenu,hPopupMenu,MF_SEPARATOR,NULL, NULL
        invoke AppendMenu,hPopupMenu,MF_STRING,IDM_EXIT,addr ExitString
        ;Starting FServe
        invoke SendMessage, hWnd, WM_COMMAND, IDM_STARTSTOP, 0

    .elseif uMsg==WM_DESTROY
        invoke ExitFserve; 
        invoke DestroyMenu,hPopupMenu
        invoke Shell_NotifyIcon,NIM_DELETE,addr note 
        invoke PostQuitMessage,NULL
         
    .elseif uMsg==WM_SIZE 
        .if wParam==SIZE_MINIMIZED 
            mov note.cbSize,sizeof NOTIFYICONDATA 
            push hWnd 
            pop note.hwnd 
            mov note.uID,IDI_TRAY 
            mov note.uFlags,NIF_ICON+NIF_MESSAGE+NIF_TIP 
            mov note.uCallbackMessage,WM_SHELLNOTIFY 
            invoke LoadIcon,hInstance, 500              ;Load freenet icon (500) for system tray
            mov note.hIcon,eax 
            invoke lstrcpy,addr note.szTip,addr AppName
            invoke ShowWindow,hWnd,SW_HIDE 
            invoke Shell_NotifyIcon,NIM_ADD,addr note 
        .endif
         
    .elseif uMsg==WM_COMMAND 
        .if lParam==0       ; msg comes from menu
           mov eax,wParam
            
            .if ax==IDM_RESTORE
                invoke Shell_NotifyIcon,NIM_DELETE,addr note 
                invoke ShowWindow,hWnd,SW_RESTORE
                
            .elseif ax==IDM_GATEWAY                    ; menu choice Open Gateway (or doubleclick on icon)
                cmp fRunning,0                  	 ; is the Node running?
                jz @F                                  ; no, then don't open the Gateway page
                invoke ShellExecute, hWnd, NULL, addr gatewayURI, NULL, NULL, 0
                @@:

            .elseif ax==IDM_FREQUEST                    ; menu choice Request Key
                ;Call Dialog DLG_FREQ /200
                invoke CreateDialogParam, hInstance, 200, hWnd, OFFSET FReqDlgProc, 0
                                
            .elseif ax==IDM_STARTSTOP                   ;menu choice Start/Stop FProxy
                .if fRunning==1                         ;is the server up?
                    call ExitFserve
                .elseif fRunning==0
                    call StartFserve
                .endif
                .if fRunning==0     ; Node was stopped or start did not suceed
                  invoke ModifyMenu,hPopupMenu,IDM_STARTSTOP,MF_BYCOMMAND,IDM_STARTSTOP,addr StartString
                  invoke ModifyMenu,hPopupMenu,IDM_GATEWAY,MF_BYCOMMAND+MF_GRAYED,IDM_GATEWAY,addr GatewayString
                  ;invoke ModifyMenu,hPopupMenu,IDM_FREQUEST,MF_BYCOMMAND+MF_GRAYED,IDM_FREQUEST,addr FrequestString
                .else               ; Node was started or stop failed
                  invoke ModifyMenu,hPopupMenu,IDM_STARTSTOP,MF_BYCOMMAND,IDM_STARTSTOP,addr StopString
                  invoke ModifyMenu,hPopupMenu,IDM_GATEWAY,MF_BYCOMMAND,IDM_GATEWAY,addr GatewayString
                  ;invoke ModifyMenu,hPopupMenu,IDM_FREQUEST,MF_BYCOMMAND,IDM_FREQUEST,addr FrequestString
                .endif
;            .elseif ax==IDM_SHOWLOG                     ; menu choice Show Log
;                ;Call Dialog DLG_0100 /100
;                invoke CreateDialogParam, hInstance, 100, hWnd, OFFSET FLogDlgProc, 0
                
            .elseif ax==IDM_CONFIGURE                   ;menu choice configure 
                mov   StartInfo.cb,SIZEOF STARTUPINFO
                mov   StartInfo.lpReserved,NULL
                mov   StartInfo.lpDesktop,NULL
                mov   StartInfo.lpTitle,NULL
                ;mov   StartInfo.dwFlags,STARTF_USESHOWWINDOW
                ;mov   StartInfo.wShowWindow,SW_MINIMIZE
                mov   StartInfo.cbReserved2,0
                mov   StartInfo.lpReserved2,NULL            
                invoke CreateProcess, addr javawpath, addr fconfig, NULL, NULL, FALSE, NORMAL_PRIORITY_CLASS, NULL, NULL,\
                ADDR StartInfo, ADDR prcInfo    ; start Config
                invoke WaitForSingleObject, prcInfo.hProcess, INFINITE      ;Wait till configuration is finished
                invoke CloseHandle, prcInfo.hThread           ; and closing the handles of the process
                invoke CloseHandle, prcInfo.hProcess
                call ExitFserve                 ; restarting the server
                call Initialize                 ; reread all necessary configs
                call StartFserve
                
            .elseif ax==IDM_EXIT                        ;otherwise menu choice exit, exiting
                invoke DestroyWindow,hWnd
            .endif 
        .endif 
    .elseif uMsg==WM_SHELLNOTIFY 
        .if wParam==IDI_TRAY 
            .if lParam==WM_RBUTTONDOWN 
                invoke GetCursorPos,addr pt 
                invoke SetForegroundWindow,hWnd 
                invoke TrackPopupMenu,hPopupMenu,TPM_RIGHTALIGN,pt.x,pt.y,NULL,hWnd,NULL 
                invoke PostMessage,hWnd,WM_NULL,0,0 
            .elseif lParam==WM_LBUTTONDBLCLK
                invoke SendMessage,hWnd,WM_COMMAND,IDM_GATEWAY,0   ;this starts FProxy configuration
                ;invoke SendMessage,hWnd,WM_COMMAND,IDM_RESTORE,0   ;this would restore the window
            .endif 
        .endif 
    .else 
        invoke DefWindowProc,hWnd,uMsg,wParam,lParam 
        ret 
    .endif 
    xor eax,eax 
    ret 
WndProc endp 
;----------------------------------------------------------------------------------------------
;FLogDlgProc proc hwndDlg:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM
 ;should return nonzero if it processes the message, and zero if it does not, except:WM_INITDIALOG
;LOCAL hFile:DWORD   ; FileHandle for logfile 
;LOCAL hMem:DWORD    ; Handle for Memory to store the logfile
;LOCAL pMem:DWORD    ; pointer to Memory
;LOCAL fileSize:DWORD    
;LOCAL byteRead:DWORD   ;number of bytes actually read

;szText FLogfile, ".\freenet.log"
  
;  .if uMsg==WM_INITDIALOG
;Use GlobalAlloc,GlobalLock,GlobalUnlock,GlobalFree (Local works as 2well)
;CreateFile,ReadFile,SetFilePointer,ReadFile,CloseHandle
;        
;        invoke CreateFile, addr FLogfile, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL
;         cmp eax,0                               ;0 on error, jump to the end then
;         jz endl2
;        mov hFile,eax                           ;save file handle otherwise
;        invoke GetFileSize, hFile, addr fileSize   ;get the Filesize
;        invoke LocalAlloc, LHND, fileSize
;         cmp eax, NULL                           ;we couldn't allocate memory? Jump to end then
;         jz endl2
;        mov hMem,eax
;        invoke LocalLock, hMem                   ;
;         cmp eax, NULL                           ;we couldn't lock memory? Jump to end then
;         jz endl2
;invoke MessageBox, NULL, addr FLogfile, addr FLogfile, MB_OK
;        mov pMem, eax
;        invoke ReadFile, hFile, pMem, addr fileSize, addr byteRead, NULL
;         cmp eax,0                               ;0 on error, jump to the end then
;         jz endl2
;invoke MessageBox, NULL, pMem, addr FLogfile, MB_OK
;        invoke SendMessage,hwndDlg,LB_ADDSTRING, 0,addr pMem
;        cmp eax,LB_ERR       ;nonzero on success
;        jnz endl1
;        invoke DestroyWindow, hwndDlg
;        endl1:
;        invoke UpdateWindow, hwndDlg            ; and refresh our new Listbox
;        endl2:
;        invoke LocalUnlock, hMem                ; freeing memory
;        invoke LocalFree, hMem
;        invoke CloseHandle, hFile               ; close file handle
;        
;        mov eax,1       ;Let Win not decide on the control to get keyboard focus
;        ret
;        
;  .elseif uMsg==WM_CLOSE        
;        invoke DestroyWindow, hwndDlg
;        mov eax,1
;        ret
;        
;  .elseif uMsg==WM_COMMAND
;      .if wParam==ID_CLOSE
;           invoke DestroyWindow, hwndDlg
;           mov eax,1
;           ret
;      .elseif wParam==ID_CLEARLOG
;      .endif
;  .endif
;ReturnZero:
;  xor eax,eax
;  ret
;FLogDlgProc endp
;----------------------------------------------------------------------------------------------
FReqDlgProc proc hwndDlg:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM
 ;should return nonzero if it processes the message, and zero if it does not, except:WM_INITDIALOG
LOCAL hCBkeytype:HWND   ; handle of the key type Combobox
LOCAL hEMkey:HWND       ; handle of the key field

  .if uMsg==WM_INITDIALOG
        invoke GetDlgItem,hwndDlg,103           ; get handle of the keytype combobox
        mov hCBkeytype, eax
        invoke GetDlgItem,hwndDlg,104           ; get the handle of the kay field
        mov hEMkey, eax

        invoke SetFocus, hEMkey                 ; and set focus to the Key field
        xor eax,eax
        ret                                     ; ret (0) to indicate we set the focus self
        

  .elseif uMsg==WM_CLOSE
        ;invoke DestroyWindow, hwndDlg
        jmp ReturnTrue
        
  .elseif uMsg==WM_COMMAND
      .if wParam==IDCANCEL
           ;invoke DestroyWindow, hwndDlg
           jmp ReturnTrue
           
      .elseif wParam==IDOK                      ; Get Key chosen
          invoke lnstr, addr gatewayURI
          invoke MemCopy, addr gatewayURI, addr buffer, eax                 ; copy the GatewayURI (without 0!) into buffer
          mov [OFFSET buffer + eax],'/'
          inc eax
          mov [OFFSET buffer + eax],0
          invoke GetDlgItemText, hwndDlg, ID_KEY, addr execbuf   , BUFLEN     ;Get whatever stands in the key fiels, returns character received
          invoke szCatStr, addr buffer, addr execbuf
          invoke ShellExecute, hwndDlg, NULL, addr buffer, NULL, NULL, 0    ; call browser gatewayURI+key
          invoke SetDlgItemText, hwndDlg, ID_KEY, addr buffer
          jmp ReturnTrue
      .endif
  .endif
  
  xor eax,eax       ;if we didn't handle it return FALSE to call defDlgProc
  ret
ReturnTrue:
  mov eax,1
  ret
FReqDlgProc endp
;----------------------------------------------------------------------------------------------

end start
;----------------------------------------------------------------------------------------------