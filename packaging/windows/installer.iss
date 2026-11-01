; Windows installer, built by the Release workflow with Inno Setup 6:
;   python wizard_images.py <images>
;   iscc /DVersion=1.0.0 /DBuild=<folder of the exported app> /DImages=<images>
;        [/DGitUrl=<Git for Windows installer URL> /DGitSha256=<its SHA-256>] /O<output folder> installer.iss
; Installs for the current user (no administrator rights needed). gitbello needs git 2.40 or
; newer: when it isn't found, a page offers to download Git for Windows (the release pinned
; by GitUrl and checked against GitSha256) and runs its installer, which asks for
; administrator rights itself. Without GitUrl the page links to git-scm.com instead.

#define App "gitbello"
#ifndef Version
	#define Version "0.0.0"
#endif
#ifndef Build
	#define Build "..\..\godot\build\windows"
#endif
#ifndef Images
	#define Images "..\..\build\wizard"
#endif

[Setup]
AppId={#App}
AppName={#App}
AppVersion={#Version}
AppVerName={#App} {#Version}
AppPublisher=Caleb Tognoli
AppPublisherURL=https://github.com/caleb-tognoli/gitbello
VersionInfoVersion={#Version}
PrivilegesRequired=lowest
; %LOCALAPPDATA%\Programs, as installing for the current user
DefaultDirName={autopf}\{#App}
DisableProgramGroupPage=yes
DisableReadyPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
WizardImageFile={#Images}\side-164.bmp,{#Images}\side-192.bmp,{#Images}\side-246.bmp,{#Images}\side-273.bmp,{#Images}\side-328.bmp,{#Images}\side-383.bmp,{#Images}\side-410.bmp
WizardSmallImageFile={#Images}\corner-55.bmp,{#Images}\corner-64.bmp,{#Images}\corner-69.bmp,{#Images}\corner-83.bmp,{#Images}\corner-92.bmp,{#Images}\corner-110.bmp,{#Images}\corner-119.bmp,{#Images}\corner-138.bmp
WizardImageAlphaFormat=defined
SetupIconFile=..\..\godot\themes\branding\icon.ico
UninstallDisplayIcon={app}\{#App}.exe
UninstallDisplayName={#App}
OutputBaseFilename={#App}-{#Version}-windows-setup
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"

[Messages]
; Choosing the folder is the last step before installing, see CurPageChanged
en.SelectDirBrowseLabel=To install, click Install. If you would like to select a different folder, click Browse.
it.SelectDirBrowseLabel=Per installare seleziona "Installa".%nPer scegliere un'altra cartella seleziona "Sfoglia".

[CustomMessages]
en.GitCaption=Git
en.GitDescription=gitbello needs Git 2.40 or newer
en.GitMissing=Git wasn't found on this computer.
en.GitTooOld=Git %1 is installed, but gitbello needs 2.40 or newer.
en.GitOffer=Download and install Git for Windows (about 70 MB)
en.GitManual=Install Git for Windows from https://git-scm.com/download/win before you open gitbello.
en.GitInstalling=Installing Git for Windows...
en.GitFailed=Git for Windows wasn't installed (%1). Install it from https://git-scm.com/download/win before you open gitbello.
it.GitCaption=Git
it.GitDescription=gitbello richiede Git 2.40 o successivo
it.GitMissing=Git non è installato su questo computer.
it.GitTooOld=È installato Git %1, ma gitbello richiede la versione 2.40 o successiva.
it.GitOffer=Scarica e installa Git for Windows (circa 70 MB)
it.GitManual=Installa Git for Windows da https://git-scm.com/download/win prima di aprire gitbello.
it.GitInstalling=Installazione di Git for Windows...
it.GitFailed=Git for Windows non è stato installato (%1). Installalo da https://git-scm.com/download/win prima di aprire gitbello.

[Files]
Source: "{#Build}\{#App}.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Build}\gitbello_gdext.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#App}"; Filename: "{app}\{#App}.exe"

[Run]
Filename: "{app}\{#App}.exe"; Description: "{cm:LaunchProgram,{#App}}"; Flags: nowait postinstall skipifsilent

[Code]
const
	MinMajor = 2;
	MinMinor = 40;

var
	GitPage: TInputOptionWizardPage;
#ifdef GitUrl
	DownloadPage: TDownloadWizardPage;
#endif
	// The version of the git found, empty when there is none
	FoundGit: String;
	GitOk: Boolean;

// "git version 2.47.1.windows.1" -> major and minor; false when it isn't that
function ParseGitVersion(Output: String; var Major, Minor: Integer): Boolean;
var
	Rest: String;
	Dot: Integer;
begin
	Result := False;
	Dot := Pos('git version ', Output);
	if Dot = 0 then
		Exit;
	Rest := Trim(Copy(Output, Dot + Length('git version '), 40));
	Dot := Pos('.', Rest);
	if Dot = 0 then
		Exit;
	Major := StrToIntDef(Copy(Rest, 1, Dot - 1), -1);
	Rest := Copy(Rest, Dot + 1, 40);
	Dot := Pos('.', Rest);
	if Dot = 0 then
		Dot := Length(Rest) + 1;
	Minor := StrToIntDef(Copy(Rest, 1, Dot - 1), -1);
	Result := (Major >= 0) and (Minor >= 0);
end;

// Runs `<Git> --version`; true with its version when it runs
function RunGitVersion(Git: String; var Version: String; var Major, Minor: Integer): Boolean;
var
	OutFile: String;
	Output: AnsiString;
	Code: Integer;
begin
	Result := False;
	OutFile := ExpandConstant('{tmp}\git-version.txt');
	DeleteFile(OutFile);
	if Exec(ExpandConstant('{cmd}'), '/C "' + Git + ' --version > "' + OutFile + '" 2>nul"', '',
		SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0)
		and LoadStringFromFile(OutFile, Output) and ParseGitVersion(String(Output), Major, Minor) then
	begin
		Version := IntToStr(Major) + '.' + IntToStr(Minor);
		Result := True;
	end;
end;

// Looks where gitbello does: PATH, then where Git for Windows installs
procedure FindGit();
var
	Candidates: array of String;
	Version: String;
	Major, Minor, I: Integer;
begin
	SetArrayLength(Candidates, 3);
	Candidates[0] := 'git';
	Candidates[1] := '"' + ExpandConstant('{commonpf64}\Git\cmd\git.exe') + '"';
	Candidates[2] := '"' + ExpandConstant('{localappdata}\Programs\Git\cmd\git.exe') + '"';
	FoundGit := '';
	GitOk := False;
	for I := 0 to GetArrayLength(Candidates) - 1 do
		if RunGitVersion(Candidates[I], Version, Major, Minor) then
		begin
			if (Major > MinMajor) or ((Major = MinMajor) and (Minor >= MinMinor)) then
			begin
				GitOk := True;
				Exit;
			end;
			if FoundGit = '' then
				FoundGit := Version;
		end;
end;

procedure InitializeWizard();
var
	Found: String;
begin
	FindGit();
	if FoundGit = '' then
		Found := CustomMessage('GitMissing')
	else
		Found := FmtMessage(CustomMessage('GitTooOld'), [FoundGit]);
#ifdef GitUrl
	GitPage := CreateInputOptionPage(wpWelcome, CustomMessage('GitCaption'),
		CustomMessage('GitDescription'), Found, False, False);
	GitPage.Add(CustomMessage('GitOffer'));
	GitPage.Values[0] := True;
	DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing),
		SetupMessage(msgPreparingDesc), nil);
#else
	GitPage := CreateInputOptionPage(wpWelcome, CustomMessage('GitCaption'),
		CustomMessage('GitDescription'), Found + #13#10#13#10 + CustomMessage('GitManual'),
		False, False);
#endif
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
	Result := (PageID = GitPage.ID) and (GitOk or WizardSilent());
end;

// With no Ready page, choosing the folder is the last step before installing
procedure CurPageChanged(CurPageID: Integer);
begin
	if CurPageID = wpSelectDir then
		WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall);
end;

#ifdef GitUrl
function WantsGit(): Boolean;
begin
	Result := not GitOk and not WizardSilent() and GitPage.Values[0];
end;

// Downloads Git for Windows on Install; a failed download leaves gitbello to install alone
function NextButtonClick(CurPageID: Integer): Boolean;
begin
	Result := True;
	if (CurPageID <> wpSelectDir) or not WantsGit() then
		Exit;
	DownloadPage.Clear();
	DownloadPage.Add('{#GitUrl}', 'git-setup.exe', '{#GitSha256}');
	DownloadPage.Show();
	try
		try
			DownloadPage.Download();
		except
			GitPage.Values[0] := False;
			if not DownloadPage.AbortedByUser then
				SuppressibleMsgBox(FmtMessage(CustomMessage('GitFailed'), [GetExceptionMessage()]),
					mbError, MB_OK, IDOK);
		end;
	finally
		DownloadPage.Hide();
	end;
end;

// Runs the Git installer once gitbello is in place. ShellExec, unlike Exec, lets it
// ask for administrator rights.
procedure CurStepChanged(CurStep: TSetupStep);
var
	Code: Integer;
	Reason: String;
begin
	if (CurStep <> ssPostInstall) or not WantsGit() then
		Exit;
	WizardForm.StatusLabel.Caption := CustomMessage('GitInstalling');
	if not ShellExec('', ExpandConstant('{tmp}\git-setup.exe'),
		'/SILENT /NORESTART /SUPPRESSMSGBOXES /SP-', '', SW_SHOW, ewWaitUntilTerminated, Code) then
		Reason := SysErrorMessage(Code)
	else if Code <> 0 then
		Reason := 'exit code ' + IntToStr(Code)
	else
		Exit;
	SuppressibleMsgBox(FmtMessage(CustomMessage('GitFailed'), [Reason]), mbError, MB_OK, IDOK);
end;
#endif
