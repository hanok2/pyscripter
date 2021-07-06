{ -----------------------------------------------------------------------------
  Unit Name: JediLspClient
  Author:    pyscripter
  Date:      16-May-2021
  Purpose:   Jedi Lsp client
  History:
  ----------------------------------------------------------------------------- }

unit JediLspClient;

interface

uses
  Winapi.Windows,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  JclNotify,
  LspClient,
  SynEditTypes,
  SynEdit,
  LspUtils,
  uEditAppIntfs;

type
  TJedi = class
  class var
    LspClient: TLspClient;
    SyncRequestTimeout: integer;
    OnInitialized: TJclNotifyEventBroadcast;
    OnShutDown: TJclNotifyEventBroadcast;
  private
    class procedure PythonVersionChanged(Sender: TObject);
    class procedure OnLspClientInitialized(Sender: TObject);
    class procedure OnLspClientShutdown(Sender: TObject);
  public
    class constructor Create;
    class destructor Destroy;
    class procedure CreateServer;
    class procedure Initialize;
    class function Ready: boolean;
    // Lsp functionality
    class procedure FindDefinitionByCoordinates(const Filename: string;
      const BC: TBufferCoord; out DefFileName: string; out DefBC: TBufferCoord);
    class function FindReferencesByCoordinates(Filename: string;
      const BC: TBufferCoord): TArray<TDocPosition>;
    class function HandleCodeCompletion(const Filename: string;
      const BC: TBufferCoord; out InsertText, DisplayText: string): boolean;
    class function ResolveCompletionItem(CCItem: string): string;
    class function HandleParamCompletion(const FileName: string;
      Editor: TSynEdit; out DisplayString, DocString: string; out StartX,
      ActiveParameter: integer): boolean;
    class function DocumentSymbols(const FileName: string): TJsonArray;
    class function SimpleHintAtCoordinates(const Filename: string;
      const BC: TBufferCoord): string;
    class function CodeHintAtCoordinates(const Filename: string;
      const BC: TBufferCoord; const Ident: string): string;
  end;

  TDocSymbols = class
    {Asynchronous symbol support for Code Explorer}
  private
    FEditor: IEditor;
    FCriticalSection: TRTLCriticalSection;
    FSymbols: TJsonArray;
    FId: Int64;
    FOnNotify: TNotifyEvent;
    procedure HandleResponse(Id: Int64; Result, Error: TJsonValue);
  public
    constructor Create(Editor: IEditor);
    destructor Destroy; override;
    procedure Lock;
    procedure Unlock;
    procedure Refresh;
    property OnNotify: TNotifyEvent read FOnNotify write FOnNotify;
  end;

implementation

uses
  System.Character,
  System.SysUtils,
  System.IOUtils,
  System.Threading,
  System.RegularExpressions,
  System.Generics.Collections,
  dmCommands,
  uCommonFunctions,
  SynEditLsp,
  cPyScripterSettings,
  StringResources,
  JvGnugettext;

{ TJedi }

class constructor TJedi.Create;
begin
  SyncRequestTimeout := 4000; // ms
  OnInitialized := TJclNotifyEventBroadcast.Create;
  OnShutDown := TJclNotifyEventBroadcast.Create;
  GI_PyControl.OnPythonVersionChange.AddHandler(PythonVersionChanged);
end;

class procedure TJedi.CreateServer;
// Creates or recreates the Server
var
  CmdLine: string;
  ServerPath: string;
const
  LspDebugFile = 'LspDebug.log';
begin
  FreeAndNil(LspClient);

  if not GI_PyControl.PythonLoaded then Exit;

  ServerPath :=
    TPath.Combine(TPyScripterSettings.LspServerPath,
    'jls\run-jedi-language-server.py');
  if not FileExists(ServerPath) then Exit;


  CmdLine :=    '"' + GI_PyControl.PythonVersion.PythonExecutable + '" -u ' +
    ServerPath;
  if PyIDEOptions.LspDebug then
  begin
    CmdLine := CmdLine + ' -v --log-file ' +
      TPath.Combine(TPyScripterSettings.UserDataPath, LspDebugFile);
  end;

  LspClient := TLspClient.Create(CmdLine);
  LspClient.OnInitialized := OnLspClientInitialized;
  LspClient.OnShutdown := OnLspClientShutdown;

  LspClient.StartServer;
  Initialize;
end;

class destructor TJedi.Destroy;
begin
  FreeAndNil(OnInitialized);
  FreeAndNil(OnShutDown);
  GI_PyControl.OnPythonVersionChange.RemoveHandler(PythonVersionChanged);
  LspClient.Free;
end;

class procedure TJedi.Initialize;
var
  ClientCapabilities: TJsonObject;     // Will be freed by Initialize
  InitializationOptions: TJsonObject;  // Will be freed by Initialize
Const
   ClientCapabilitiesJson =
    '{"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":true}}}';
   InitializationOptionsLsp =
    '{'#13#10 +
    '	  "diagnostics": {'#13#10 +
    '		"enable": false'#13#10 +
    '	  },'#13#10 +
    '   "completion": {'#13#10 +
    '       "disableSnippets": true,'#13#10 +
    '       "resolveEagerly": false'#13#10 +
    '   },'#13#10 +
    '	  "jediSettings": {'#13#10 +
    '		"autoImportModules": [%s],'#13#10 +
    '		"caseInsensitiveCompletion": %s'#13#10 +
    '	  }'#13#10 +
    '}';

  function QuotePackages(Packages: string): string;
  begin
    var Arr := Packages.Split([',']);
    if Length(Arr) = 0 then Exit('');

    for var I := 0 to Length(Arr) - 1 do
      Arr[I] := '"' + Trim(Arr[I]) + '"';

    Result := String.Join(',', Arr);
  end;

begin
  if LspClient.Status <> lspStarted then Exit;

  ClientCapabilities := TJsonObject.Create;
  ClientCapabilities.Parse(TEncoding.UTF8.GetBytes(ClientCapabilitiesJson), 0);
  InitializationOptions := TJsonObject.Create;
  InitializationOptions.Parse(TEncoding.UTF8.GetBytes(
    Format(InitializationOptionsLsp, [QuotePackages(PyIDEOptions.SpecialPackages),
    BoolToStr(not PyIDEOptions.CodeCompletionCaseSensitive, True).ToLower])), 0);

  LspClient.Initialize('PyScripter', ApplicationVersion, ClientCapabilities,
    InitializationOptions);
end;

class procedure TJedi.OnLspClientInitialized(Sender: TObject);
begin
  if Assigned(OnInitialized) and (OnInitialized.HandlerCount > 0) then
    TThread.ForceQueue(nil, procedure
    begin
      OnInitialized.Notify(LspClient);
    end);
end;

class procedure TJedi.OnLspClientShutdown(Sender: TObject);
begin
  if Assigned(OnShutDown) and (OnShutDown.HandlerCount > 0) then
    TThread.ForceQueue(nil, procedure
    begin
      OnShutdown.Notify(LspClient);
    end);
end;

class procedure TJedi.PythonVersionChanged(Sender: TObject);
begin
  CreateServer;
end;

class function TJedi.Ready: boolean;
begin
  Result := Assigned(LspClient) and (LspClient.Status = lspInitialized);
end;


{$Region 'Lsp functionality'}

class procedure TJedi.FindDefinitionByCoordinates(const Filename: string;
  const BC: TBufferCoord; out DefFileName: string; out DefBC: TBufferCoord);
var
  Param: TJsonObject;
  AResult, Error: TJsonValue;
  Uri: string;
  Line, Char: integer;
begin
  DefFileName := '';
  if not Ready or (FileName = '') then Exit;

  Param := TSmartPtr.Make(LspDocPosition(FileName, BC))();
  LspClient.SyncRequest('textDocument/definition', Param.ToJSon, AResult,
    Error, SyncRequestTimeout);

  if Assigned(AResult) and AResult.TryGetValue<string>('[0].uri', Uri) and
    AResult.TryGetValue<integer>('[0].range.start.line', Line) and
    AResult.TryGetValue<integer>('[0].range.start.character', Char) then
  begin
    DefFileName := FilePathFromUrl(Uri);
    DefBC := BufferCoord(Char + 1, Line + 1);
  end;

  FreeAndNil(AResult);
  FreeAndNil(Error);
end;

class function TJedi.FindReferencesByCoordinates(Filename: string;
  const BC: TBufferCoord): TArray<TDocPosition>;
var
  Param: TJsonObject;
  Context: TJsonObject;
  AResult, Error: TJsonValue;
begin
  SetLength(Result, 0);
  if not Ready or (FileName = '') then Exit;

  Param := TSmartPtr.Make(LspDocPosition(FileName, BC))();
  Context := TJsonObject.Create;
  Context.AddPair('includeDeclaration', TJSONBool.Create(True));
  Param.AddPair('context', Context);

  LspClient.SyncRequest('textDocument/references', Param.ToJSon, AResult, Error,
    4 * SyncRequestTimeout);

  if AResult is TJSONArray then
  begin
    SetLength(Result, TJsonArray(AResult).Count);

    for var I := 0 to TJsonArray(AResult).Count -1 do
    begin
      var Location := TJsonArray(AResult).Items[I];
      if not LspLocationToDocPosition(Location, Result[I]) then
      begin
        // Error happened
        SetLength(Result, 0);
        Break;
      end;
    end;
  end;

  FreeAndNil(AResult);
  FreeAndNil(Error);
end;

class function TJedi.HandleCodeCompletion(const Filename: string;
  const BC: TBufferCoord; out InsertText, DisplayText: string): boolean;

  function KindToImageIndex(Kind: TLspCompletionItemKind): integer;
  begin
    case Kind of
      TLspCompletionItemKind._Constructor,
      TLspCompletionItemKind.Method:     Result := Integer(TCodeImages.Method);
      TLspCompletionItemKind._Function:  Result := Integer(TCodeImages.Func);
      TLspCompletionItemKind.Variable:   Result := Integer(TCodeImages.Variable);
      TLspCompletionItemKind._Class:     Result := Integer(TCodeImages.Klass);
      TLspCompletionItemKind.Module:     Result := Integer(TCodeImages.Module);
      TLspCompletionItemKind.Field,
      TLspCompletionItemKind._Property:  Result := Integer(TCodeImages.Field);
      TLspCompletionItemKind.Keyword:    Result := Integer(TCodeImages.Keyword);
    else
      Result := -1;
    end;
  end;

var
  Param: TJsonObject;
  AResult, Error: TJsonValue;
  CompletionItems : TCompletionItems;
begin
  if not Ready or (FileName = '') then Exit(False);

  Param := TSmartPtr.Make(LspDocPosition(FileName, BC))();
  LspClient.SyncRequest('textDocument/completion', Param.ToJSon, AResult, Error,
    SyncRequestTimeout);
  CompletionItems := LspCompletionItems(AResult);

  if Length(CompletionItems) > 0 then
  begin
    // process completion items
    InsertText := '';
    DisplayText := '';
    for var Item in CompletionItems do
    begin
      InsertText := InsertText + Item._label + #10;
      var ImageIndex := KindToImageIndex(TLspCompletionItemKind(Item.kind));
      DisplayText := DisplayText + Format('\Image{%d}\hspace{8}%s', [ImageIndex, Item._label]) + #10;
    end;
    Result := True;
  end
  else
    Result := False;

  FreeAndNil(AResult);
  FreeAndNil(Error);
end;

class function TJedi.ResolveCompletionItem(CCItem: string): string;
var
  AResult, Error: TJsonValue;
begin
  if not Ready then Exit('');

  var Item := TSmartPtr.Make(TJsonObject.Create)();
  Item.AddPair('label', TJSONString.Create(CCItem));

  LspClient.SyncRequest('completionItem/resolve', Item.ToJson, AResult, Error,
    SyncRequestTimeout div 10);
  if Assigned(AResult) and AResult.TryGetValue<string>('documentation.value', Result) then
    Result := GetLineRange(Result, 1, 20)
  else
     Result := '';

  FreeAndNil(AResult);
  FreeAndNil(Error);
end;

class function TJedi.HandleParamCompletion(const FileName: string;
  Editor: TSynEdit; out DisplayString, DocString: string; out StartX,
  ActiveParameter: integer): boolean;
var
  TmpX: integer;
  Line: string;
  Param: TJsonObject;
  AResult, Error: TJsonValue;
  Signature : TJsonValue;
begin
  if not Ready or (FileName = '') then Exit(False);

  // Get Completion for the current word
  Line := Editor.LineText;

  TmpX := Editor.CaretX;
  if TmpX > Length(Line) then
    TmpX := Length(Line) + 1;
  while (TmpX > 1) and ((Line[TmpX-1] = '_') or Line[TmpX-1].IsLetterOrDigit) do
    Dec(TmpX);

  Param := TSmartPtr.Make(LspDocPosition(FileName, BufferCoord(TmpX, Editor.CaretY)))();
  LspClient.SyncRequest('textDocument/signatureHelp', Param.ToJSon, AResult,
    Error, SyncRequestTimeout);

  if Assigned(AResult) and AResult.TryGetValue('signatures[0]', Signature) then
  begin
    DisplayString := '';
    DocString := '';
    Signature.TryGetValue<string>('label', DisplayString);
    Signature.TryGetValue<string>('documentation.value', DocString);
    if not AResult.TryGetValue<integer>('activeParameter', ActiveParameter) then
      ActiveParameter := 0;
    StartX := 1;

    var RightPar := DisplayString.LastDelimiter(')');
    if RightPar >= 0 then
      Delete(DisplayString, RightPar + 1, 1);

    var LeftPar :=DisplayString.IndexOf('(');
    if LeftPar >= 0 then
    begin
      var FunctionName := Copy(DisplayString, 1, LeftPar).Trim;
      DisplayString := Copy(DisplayString, LeftPar + 2);
      var Match := TRegEx.Match(Line, FunctionName + '\s*(\()');
      if Match.Success then
        StartX := Match.Groups[1].Index;
    end;
    Result := True;
  end
  else
    Result := False;

  FreeAndNil(AResult);
  FreeAndNil(Error);
end;

class function TJedi.SimpleHintAtCoordinates(const Filename: string;
  const BC: TBufferCoord): string;
var
  Param: TJsonObject;
  AResult, Error: TJsonValue;
begin
  Result := '';
  if not Ready or (FileName = '') then Exit;

  Param := TSmartPtr.Make(LspDocPosition(FileName, BC))();
  TJedi.LspClient.SyncRequest('textDocument/hover', Param.ToJSon, AResult,
    Error, 1000);

  if Assigned(AResult) then
    AResult.TryGetValue<string>('contents.value', Result);

  FreeAndNil(AResult);
  FreeAndNil(Error);
end;

class function TJedi.CodeHintAtCoordinates(const Filename: string;
  const BC: TBufferCoord; const Ident: string): string;
var
  Param: TJsonObject;
  AResult, Error: TJsonValue;
  DefFileName: string;
  DefBC: TBufferCoord;
  ModuleName,
  FunctionName,
  ParentName,
  Line,
  DefinedIn,
  Fmt: string;
  IsVariable,
  IsClass: Boolean;
begin
  Result := '';
  if not Ready or (FileName = '') then Exit;

  Param := TSmartPtr.Make(LspDocPosition(FileName, BC))();
  LspClient.SyncRequest('textDocument/hover', Param.ToJSon, AResult,
    Error, SyncRequestTimeout);

  if Assigned(AResult) then
  begin
    IsVariable := AResult.Null;  // No Code hint is produced for variables
    if not IsVariable then
    begin
      AResult.TryGetValue<string>('contents.value', Result);
      Result := GetLineRange(Result, 1, 20, True);
    end;

    FindDefinitionByCoordinates(FileName, BC, DefFileName, DefBC);
    if (DefFileName <> '') then begin
      ModuleName := TPath.GetFileNameWithoutExtension(DefFileName);
      Line := GetNthSourceLine(DefFileName, DefBC.Line);
      FunctionName := '';
      IsClass := False;
      if Line <> '' then
      begin
        var Match := TRegEx.Match(Line, '\s*def\s+(\w+)');
        if Match.Success then
          FunctionName := Match.Groups[1].Value;
        IsClass := TRegEx.Match(Line, '\s*class\s+' + Ident).Success;
      end;

      if (DefBC.Line = 1) and (DefBC.Char = 1) then
      begin
        // we have a module
        Result := Format(_(SModuleImportCodeHint), [ModuleName]) +
          '<br><br>' + Result;
      end
      else if IsVariable then
      begin
        // variable
        DefinedIn := Format(_(SFilePosInfoCodeHint),
          [DefFileName, DefBC.Line, DefBC.Char,
           ModuleName, DefBC.Line]);

        if not SameFileName(DefFileName, FileName) then
        begin
          Fmt := _(SImportedVariableCodeHint);
          ParentName := ModuleName;
        end
        else if DefBC.Char = 1 then
        begin
          Fmt := _(SGlobalVariableCodeHint);
          ParentName := ModuleName;
        end
        else if FunctionName <> '' then
        begin
          Fmt := _(SFunctionParameterCodeHint);
          ParentName := FunctionName;
        end
        else
        begin
          Fmt := _(SVariableCodeHint);
          ParentName := '';
        end;
        Result := Format(Fmt, [Ident, ParentName, DefinedIn]);
      end
      else
      begin
        // class of function
        if FunctionName <> '' then
          Result := '<b>function</b> ' + Result
        else if IsClass then
          Result := '<b>class</b> ' + Result;
      end;
    end;
  end;

  FreeAndNil(AResult);
  FreeAndNil(Error);
end;

class function TJedi.DocumentSymbols(const FileName: string): TJsonArray;
var
  AResult, Error: TJsonValue;
begin
  if not Ready then Exit(nil);

  var Param := TSmartPtr.Make(TJsonObject.Create)();
  Param.AddPair('textDocument', LspTextDocumentIdentifier(FileName));

  LspClient.SyncRequest('textDocument/documentSymbol', Param.ToJson, AResult, Error,
    SyncRequestTimeout * 4);

  if AResult is TJsonArray then
     Result := TJsonArray(AResult)
  else
  begin
    FreeAndNil(AResult);
    Result := nil;
  end;

  FreeAndNil(Error);
end;

{$EndRegion 'Lsp functionality'}

{ TDocSymbols }

constructor TDocSymbols.Create(Editor: IEditor);
begin
  inherited Create;
  FEditor:= Editor;
  FCriticalSection.Initialize;
end;

destructor TDocSymbols.Destroy;
begin
  FCriticalSection.Destroy;
  inherited;
end;

procedure TDocSymbols.HandleResponse(Id: Int64; Result, Error: TJsonValue);
begin
  if Id = fId then
  begin
    Lock;
    try

    finally
      UnLock;
    end;
  end;
end;

procedure TDocSymbols.Lock;
begin
  FCriticalSection.Enter;
end;

procedure TDocSymbols.Refresh;
begin
  if not TJedi.Ready then Exit;

  var Param := TSmartPtr.Make(TJsonObject.Create)();
  Param.AddPair('textDocument', LspTextDocumentIdentifier(FEditor.GetFileNameOrTitle));

  var Id := TJedi.LspClient.Request('textDocument/documentSymbol', Param.ToJson, HandleResponse);
  AtomicExchange(FId, Id);
end;

procedure TDocSymbols.Unlock;
begin
  FCriticalSection.Leave;
end;

end.
