#include "UserMenu.h"
#include "../main.h"
#include "Console.h"
#include "../Settings.h"

#include <algorithm>
#include <atomic>
#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

/* ------------------------------------------------------------------------- */
/*  HUD palette                                                              */
/* ------------------------------------------------------------------------- */
namespace
{
    const ImU32 COL_HEADER      = IM_COL32(8, 23, 33, 255);
    const ImU32 COL_PANEL       = IM_COL32(7, 20, 29, 255);
    const ImU32 COL_PANEL_HOVER = IM_COL32(12, 34, 45, 255);
    const ImU32 COL_CONSOLE     = IM_COL32(2, 7, 11, 255);
    const ImU32 COL_BORDER      = IM_COL32(20, 64, 77, 255);
    const ImU32 COL_BORDER_SOFT = IM_COL32(15, 45, 55, 255);
    const ImU32 COL_DIVIDER     = IM_COL32(0, 95, 108, 90);
    const ImU32 COL_ACCENT      = IM_COL32(0, 229, 255, 255);
    const ImU32 COL_ACCENT_DIM  = IM_COL32(0, 132, 150, 255);
    const ImU32 COL_TEXT        = IM_COL32(190, 240, 250, 255);
    const ImU32 COL_TEXT_DIM    = IM_COL32(85, 145, 160, 255);
    const ImU32 COL_TEXT_SOFT   = IM_COL32(55, 105, 120, 255);
    const ImU32 COL_LABEL       = IM_COL32(70, 200, 215, 255);
    const ImU32 COL_VIOLET      = IM_COL32(158, 138, 255, 235);
    const ImU32 COL_GREEN       = IM_COL32(48, 235, 158, 255);
    const ImU32 COL_RED         = IM_COL32(255, 92, 112, 255);
    const ImU32 COL_RED_DIM     = IM_COL32(150, 45, 60, 255);
    const ImU32 COL_AMBER       = IM_COL32(255, 196, 84, 255);
    const ImU32 COL_ON_ACCENT   = IM_COL32(2, 22, 27, 255);

    static std::atomic<bool> GDumpRunning{ false };
    static std::atomic<bool> GHasRun{ false };
    static bool GRecVisible = true;

    /* --------------------------------------------------------------------- */
    /*  Small text helpers (the HUD uses explicit pixel sizes)               */
    /* --------------------------------------------------------------------- */
    static float TextWidth(ImFont* F, float Size, const std::string& Text)
    {
        return F->CalcTextSizeA(Size, FLT_MAX, 0.0f, Text.c_str()).x;
    }

    static void DrawText(ImDrawList* DL, ImFont* F, float Size, ImVec2 Pos, ImU32 Col, const std::string& Text)
    {
        if (!Text.empty())
            DL->AddText(F, Size, Pos, Col, Text.c_str());
    }

    static void DrawBoldText(ImDrawList* DL, ImFont* F, float Size, ImVec2 Pos, ImU32 Col, const std::string& Text)
    {
        DrawText(DL, F, Size, Pos, Col, Text);
        DrawText(DL, F, Size, ImVec2(Pos.x + 0.6f, Pos.y), Col, Text);
    }

    static std::string Ellipsize(ImFont* F, float Size, const std::string& Text, float MaxWidth)
    {
        if (TextWidth(F, Size, Text) <= MaxWidth)
            return Text;
        if (MaxWidth <= 0.0f)
            return std::string();

        const std::string Suffix = "...";
        if (TextWidth(F, Size, Suffix) > MaxWidth)
            return std::string();

        std::string Result;
        for (char C : Text)
        {
            std::string Candidate = Result + C + Suffix;
            if (TextWidth(F, Size, Candidate) > MaxWidth)
                break;
            Result += C;
        }
        return Result + Suffix;
    }

    static std::string TrimLog(std::string S)
    {
        while (!S.empty() && (S.back() == '\n' || S.back() == '\r' || S.back() == ' ' || S.back() == '\t'))
            S.pop_back();
        return S;
    }

    /* Greedy word-wrap with a hard break for long paths. */
    static std::vector<std::string> WrapText(ImFont* F, float Size, const std::string& Text, float MaxWidth)
    {
        std::vector<std::string> Lines;
        std::string Current;

        if (MaxWidth <= 0.0f)
            MaxWidth = 20.0f;

        size_t ParagraphStart = 0;
        while (ParagraphStart <= Text.size())
        {
            const size_t Newline = Text.find('\n', ParagraphStart);
            const std::string Paragraph = Text.substr(
                ParagraphStart,
                Newline == std::string::npos ? std::string::npos : Newline - ParagraphStart);

            size_t Cursor = 0;
            while (Cursor < Paragraph.size())
            {
                while (Cursor < Paragraph.size() && Paragraph[Cursor] == ' ')
                    ++Cursor;
                if (Cursor >= Paragraph.size())
                    break;

                const size_t Space = Paragraph.find(' ', Cursor);
                std::string Word = Paragraph.substr(
                    Cursor,
                    Space == std::string::npos ? std::string::npos : Space - Cursor);

                const std::string Candidate = Current.empty() ? Word : Current + " " + Word;
                if (MaxWidth <= 0.0f || TextWidth(F, Size, Candidate) <= MaxWidth)
                {
                    Current = Candidate;
                }
                else
                {
                    if (!Current.empty())
                    {
                        Lines.push_back(Current);
                        Current.clear();
                    }

                    while (TextWidth(F, Size, Word) > MaxWidth && Word.size() > 1)
                    {
                        size_t Take = 1;
                        while (Take < Word.size() &&
                               TextWidth(F, Size, Word.substr(0, Take + 1)) <= MaxWidth)
                        {
                            ++Take;
                        }
                        Lines.push_back(Word.substr(0, Take));
                        Word.erase(0, Take);
                    }
                    Current = Word;
                }

                if (Space == std::string::npos)
                    break;
                Cursor = Space + 1;
            }

            if (!Current.empty())
            {
                Lines.push_back(Current);
                Current.clear();
            }

            if (Newline == std::string::npos)
                break;
            ParagraphStart = Newline + 1;
        }

        if (Lines.empty())
            Lines.emplace_back();
        return Lines;
    }

    /* --------------------------------------------------------------------- */
    /*  Vector icons                                                         */
    /* --------------------------------------------------------------------- */
    enum class HudIcon
    {
        None,
        Bolt,
        Copy,
        Trash,
        Power,
        Minus,
        Close,
        Rec,
        Folder,
        Prompt,
    };

    static void DrawIcon(ImDrawList* DL, HudIcon Icon, ImVec2 C, float S, ImU32 Col)
    {
        switch (Icon)
        {
        case HudIcon::Bolt:
        {
            ImVec2 P[6] = {
                ImVec2(C.x + S * 0.13f, C.y - S * 0.50f),
                ImVec2(C.x - S * 0.30f, C.y + S * 0.08f),
                ImVec2(C.x - S * 0.02f, C.y + S * 0.08f),
                ImVec2(C.x - S * 0.14f, C.y + S * 0.50f),
                ImVec2(C.x + S * 0.30f, C.y - S * 0.06f),
                ImVec2(C.x + S * 0.02f, C.y - S * 0.06f),
            };
            DL->AddPolyline(P, 6, Col, ImDrawFlags_Closed, 1.5f);
            break;
        }
        case HudIcon::Copy:
        {
            const float W = S * 0.30f;
            const float H = S * 0.34f;
            DL->AddRect(ImVec2(C.x - S * 0.26f, C.y - S * 0.24f),
                        ImVec2(C.x - S * 0.26f + W, C.y - S * 0.24f + H), Col, 1.5f, 0, 1.2f);
            DL->AddRect(ImVec2(C.x - S * 0.04f, C.y - S * 0.03f),
                        ImVec2(C.x - S * 0.04f + W, C.y - S * 0.03f + H), Col, 1.5f, 0, 1.2f);
            break;
        }
        case HudIcon::Trash:
        {
            DL->AddLine(ImVec2(C.x - S * 0.24f, C.y - S * 0.25f),
                        ImVec2(C.x + S * 0.24f, C.y - S * 0.25f), Col, 1.2f);
            DL->AddLine(ImVec2(C.x - S * 0.06f, C.y - S * 0.31f),
                        ImVec2(C.x + S * 0.06f, C.y - S * 0.31f), Col, 1.2f);
            DL->AddRect(ImVec2(C.x - S * 0.18f, C.y - S * 0.18f),
                        ImVec2(C.x + S * 0.18f, C.y + S * 0.32f), Col, 1.5f, 0, 1.2f);
            DL->AddLine(ImVec2(C.x - S * 0.06f, C.y - S * 0.10f),
                        ImVec2(C.x - S * 0.06f, C.y + S * 0.22f), Col, 1.0f);
            DL->AddLine(ImVec2(C.x + S * 0.06f, C.y - S * 0.10f),
                        ImVec2(C.x + S * 0.06f, C.y + S * 0.22f), Col, 1.0f);
            break;
        }
        case HudIcon::Power:
        {
            DL->PathArcTo(C, S * 0.30f, -2.827f, 2.827f);
            DL->PathStroke(Col, 0, 1.5f);
            DL->AddLine(ImVec2(C.x, C.y - S * 0.36f), ImVec2(C.x, C.y + S * 0.02f), Col, 1.5f);
            break;
        }
        case HudIcon::Minus:
            DL->AddLine(ImVec2(C.x - S * 0.22f, C.y), ImVec2(C.x + S * 0.22f, C.y), Col, 1.6f);
            break;
        case HudIcon::Close:
            DL->AddLine(ImVec2(C.x - S * 0.20f, C.y - S * 0.20f),
                        ImVec2(C.x + S * 0.20f, C.y + S * 0.20f), Col, 1.5f);
            DL->AddLine(ImVec2(C.x + S * 0.20f, C.y - S * 0.20f),
                        ImVec2(C.x - S * 0.20f, C.y + S * 0.20f), Col, 1.5f);
            break;
        case HudIcon::Rec:
            DL->AddCircleFilled(C, S * 0.16f, Col);
            break;
        case HudIcon::Folder:
        {
            DL->AddRect(ImVec2(C.x - S * 0.34f, C.y - S * 0.20f),
                        ImVec2(C.x + S * 0.34f, C.y + S * 0.24f), Col, 1.5f, 0, 1.2f);
            DL->AddLine(ImVec2(C.x - S * 0.14f, C.y - S * 0.20f),
                        ImVec2(C.x - S * 0.14f, C.y - S * 0.30f), Col, 1.2f);
            DL->AddLine(ImVec2(C.x - S * 0.14f, C.y - S * 0.30f),
                        ImVec2(C.x + S * 0.10f, C.y - S * 0.30f), Col, 1.2f);
            break;
        }
        case HudIcon::Prompt:
            DL->AddLine(ImVec2(C.x - S * 0.26f, C.y - S * 0.20f),
                        ImVec2(C.x - S * 0.02f, C.y), Col, 1.4f);
            DL->AddLine(ImVec2(C.x - S * 0.26f, C.y + S * 0.20f),
                        ImVec2(C.x - S * 0.02f, C.y), Col, 1.4f);
            DL->AddLine(ImVec2(C.x + S * 0.08f, C.y + S * 0.20f),
                        ImVec2(C.x + S * 0.30f, C.y + S * 0.20f), Col, 1.4f);
            break;
        case HudIcon::None:
        default:
            break;
        }
    }

    /* --------------------------------------------------------------------- */
    /*  Widgets                                                              */
    /* --------------------------------------------------------------------- */
    static bool HudButton(const char* Id, const char* Label, ImVec2 Size, HudIcon Icon,
                          bool bPrimary, bool bActive, bool bEnabled, ImU32 Accent)
    {
        ImGui::PushID(Id);
        const bool Pressed = ImGui::InvisibleButton("##hud", Size);
        const bool Hovered = ImGui::IsItemHovered();
        const ImVec2 P0 = ImGui::GetItemRectMin();
        const ImVec2 P1 = ImGui::GetItemRectMax();
        ImDrawList* DL = ImGui::GetWindowDrawList();
        ImFont* F = ImGui::GetFont();

        ImU32 Fill = COL_PANEL;
        ImU32 Border = COL_BORDER;
        ImU32 TextColor = COL_TEXT;

        if (!bEnabled)
        {
            Fill = IM_COL32(6, 14, 20, 255);
            Border = COL_BORDER_SOFT;
            TextColor = COL_TEXT_SOFT;
        }
        else if (bPrimary)
        {
            Fill = Accent;
            Border = IM_COL32(140, 250, 255, 255);
            TextColor = COL_ON_ACCENT;
        }
        else if (bActive)
        {
            Fill = IM_COL32(8, 54, 60, 255);
            Border = Accent;
            TextColor = Accent;
        }
        else if (Hovered)
        {
            Fill = COL_PANEL_HOVER;
            Border = COL_ACCENT_DIM;
            TextColor = IM_COL32(215, 250, 255, 255);
        }

        DL->AddRectFilled(P0, P1, Fill, 5.0f);
        DL->AddRect(P0, P1, Border, 5.0f, 0, 1.0f);

        if (bPrimary && bEnabled)
        {
            DL->AddLine(ImVec2(P0.x + 5.0f, P0.y + 1.0f),
                        ImVec2(P1.x - 5.0f, P0.y + 1.0f), IM_COL32(210, 255, 255, 180), 1.0f);
        }

        const float IconSize = 12.0f;
        const float TextSize = 10.0f;
        const float Gap = Label[0] ? 6.0f : 0.0f;
        const float LabelWidth = Label[0] ? TextWidth(F, TextSize, Label) : 0.0f;
        const float ContentWidth = (Icon == HudIcon::None ? 0.0f : IconSize) +
                                   (Icon != HudIcon::None && Label[0] ? Gap : 0.0f) +
                                   LabelWidth;
        float X = P0.x + (Size.x - ContentWidth) * 0.5f;
        const float CY = (P0.y + P1.y) * 0.5f;

        if (Icon != HudIcon::None)
        {
            DrawIcon(DL, Icon, ImVec2(X + IconSize * 0.5f, CY), IconSize, TextColor);
            X += IconSize + Gap;
        }

        if (Label[0])
        {
            DL->AddText(F, TextSize, ImVec2(X, CY - F->CalcTextSizeA(TextSize, FLT_MAX, 0.0f, Label).y * 0.5f),
                        TextColor, Label);
        }

        ImGui::PopID();
        return bEnabled && Pressed;
    }

    static bool HudWindowButton(const char* Id, HudIcon Icon, bool bDanger)
    {
        ImGui::PushID(Id);
        const bool Pressed = ImGui::InvisibleButton("##hudwin", ImVec2(24.0f, 24.0f));
        const bool Hovered = ImGui::IsItemHovered();
        const ImVec2 P0 = ImGui::GetItemRectMin();
        const ImVec2 P1 = ImGui::GetItemRectMax();
        ImDrawList* DL = ImGui::GetWindowDrawList();

        const ImU32 Base = bDanger ? COL_RED_DIM : COL_BORDER;
        const ImU32 Fill = Hovered ? (bDanger ? IM_COL32(70, 18, 26, 255) : COL_PANEL_HOVER) : IM_COL32(5, 16, 23, 255);
        const ImU32 Border = Hovered ? (bDanger ? COL_RED : COL_ACCENT) : Base;
        const ImU32 IconCol = Hovered ? (bDanger ? COL_RED : COL_ACCENT) : (bDanger ? IM_COL32(190, 80, 95, 255) : COL_TEXT_DIM);

        DL->AddRectFilled(P0, P1, Fill, 5.0f);
        DL->AddRect(P0, P1, Border, 5.0f, 0, 1.0f);
        DrawIcon(DL, Icon, ImVec2((P0.x + P1.x) * 0.5f, (P0.y + P1.y) * 0.5f), 10.0f, IconCol);

        ImGui::PopID();
        return Pressed;
    }

    static void DrawStatusPill(ImDrawList* DL, ImFont* F, ImVec2 Pos, float Width,
                               const std::string& Label, ImU32 Accent, bool bPulse)
    {
        const float H = 20.0f;
        DL->AddRectFilled(Pos, ImVec2(Pos.x + Width, Pos.y + H), IM_COL32(5, 26, 30, 255), H * 0.5f);
        DL->AddRect(Pos, ImVec2(Pos.x + Width, Pos.y + H), IM_COL32(0, 105, 96, 220), H * 0.5f, 0, 1.0f);

        const ImVec2 Dot(Pos.x + 10.0f, Pos.y + H * 0.5f);
        if (bPulse)
        {
            const float Pulse = 0.5f + 0.5f * std::sin((float)ImGui::GetTime() * 4.0f);
            DL->AddCircleFilled(Dot, 5.0f + Pulse * 2.0f, IM_COL32(255, 196, 84, (int)(30 + Pulse * 40)));
        }
        DL->AddCircleFilled(Dot, 3.4f, Accent);

        DL->AddText(F, 9.0f, ImVec2(Pos.x + 19.0f, Pos.y + (H - 9.0f) * 0.5f - 1.0f), COL_TEXT, Label.c_str());
    }

    static void DrawRecPill(ImDrawList* DL, ImFont* F, ImVec2 Pos, float Width, bool bVisible)
    {
        const float H = 20.0f;
        DL->AddRectFilled(Pos, ImVec2(Pos.x + Width, Pos.y + H), IM_COL32(5, 14, 20, 255), H * 0.5f);
        DL->AddRect(Pos, ImVec2(Pos.x + Width, Pos.y + H), COL_BORDER, H * 0.5f, 0, 1.0f);

        DrawIcon(DL, HudIcon::Rec, ImVec2(Pos.x + 11.0f, Pos.y + H * 0.5f), 10.0f,
                 bVisible ? COL_RED : COL_TEXT_SOFT);
        const char* Label = bVisible ? "REC: VIS" : "REC: OFF";
        DL->AddText(F, 8.5f, ImVec2(Pos.x + 19.0f, Pos.y + (H - 8.5f) * 0.5f - 0.5f),
                    bVisible ? COL_TEXT : COL_TEXT_DIM, Label);
    }

    /* --------------------------------------------------------------------- */
    /*  Metadata / path helpers                                              */
    /* --------------------------------------------------------------------- */
    struct BundleMetadata
    {
        std::string Name;
        std::string Version;
        std::string Identifier;
    };

    static std::string ToStd(NSString* Value)
    {
        if (!Value)
            return {};
        const char* Utf8 = [Value UTF8String];
        return Utf8 ? std::string(Utf8) : std::string();
    }

    static const BundleMetadata& GetBundleMetadata()
    {
        static BundleMetadata Meta;
        static bool bLoaded = false;
        if (!bLoaded)
        {
            bLoaded = true;
            NSDictionary* Info = [[NSBundle mainBundle] infoDictionary];
            if (Info)
            {
                Meta.Identifier = ToStd(Info[@"CFBundleIdentifier"]);
                Meta.Name = ToStd(Info[@"CFBundleDisplayName"]);
                if (Meta.Name.empty())
                    Meta.Name = ToStd(Info[@"CFBundleName"]);
                Meta.Version = ToStd(Info[@"CFBundleShortVersionString"]);
                if (Meta.Version.empty())
                    Meta.Version = ToStd(Info[@"CFBundleVersion"]);
            }
        }
        return Meta;
    }

    static std::string GetFooterPath(bool bRunning)
    {
        /* The dumper writes GameName/GameVersion and bIsPUBGProfile from its
         * worker thread.  Cache the display string while idle and reuse it
         * during a run so the UI never races those std::strings. */
        static std::string Cached;
        static bool bHasCache = false;

        if (bRunning)
            return bHasCache ? Cached : std::string("~/Documents/");

        std::string Display;

        const std::string Root = Settings::Generator::SDKGenerationPath;
        const char* HomeEnv = std::getenv("HOME");
        const std::string Home = HomeEnv ? HomeEnv : "";
        if (!Root.empty() && !Home.empty() && Root.rfind(Home, 0) == 0)
            Display = "~" + Root.substr(Home.size());
        else
            Display = Root.empty() ? "~" : Root;

        Display += "/Documents/";

        if (Settings::Internal::bIsPUBGProfile)
        {
            Display += "SDKGen/";
            if (!Settings::Generator::GameName.empty())
            {
                Display += Settings::Generator::GameName;
                Display += "_(v";
                Display += Settings::Generator::GameVersion.empty()
                    ? "UnknownVersion"
                    : Settings::Generator::GameVersion;
                Display += ")_64Bit/";
            }
        }
        else if (!Settings::Generator::GameName.empty())
        {
            if (!Settings::Generator::GameVersion.empty())
                Display += Settings::Generator::GameVersion + "-";
            Display += Settings::Generator::GameName + "/";
        }

        Cached = Display;
        bHasCache = true;
        return Display;
    }

    static void CopyLogsToClipboard(const std::vector<Output>& Logs)
    {
        std::string Text;
        for (const Output& Entry : Logs)
        {
            const char* Tag = Entry.type == 1 ? "ERR" : Entry.type == 2 ? "OK" : "INFO";
            Text += "[";
            Text += Entry.time;
            Text += "] [";
            Text += Tag;
            Text += "] ";
            Text += TrimLog(Entry.text);
            Text += "\n";
        }

        NSString* Payload = [NSString stringWithUTF8String:Text.c_str()];
        if (!Payload)
            return;
        [UIPasteboard generalPasteboard].string = Payload;
    }

    /* --------------------------------------------------------------------- */
    /*  Log rows                                                             */
    /* --------------------------------------------------------------------- */
    static float DrawLogRow(ImDrawList* DL, ImFont* F, ImVec2 Pos, float Width,
                            const Output& Entry, bool bNarrow)
    {
        const bool bError = Entry.type == 1;
        const bool bDone = Entry.type == 2;

        const ImU32 BadgeFill = bError ? IM_COL32(95, 25, 36, 255)
                              : bDone ? IM_COL32(16, 90, 64, 255)
                                      : IM_COL32(10, 70, 84, 255);
        const ImU32 BadgeBorder = bError ? COL_RED
                                : bDone ? COL_GREEN
                                        : IM_COL32(0, 200, 220, 255);
        const ImU32 BadgeText = bError ? IM_COL32(255, 170, 180, 255)
                              : bDone ? IM_COL32(160, 255, 215, 255)
                                      : IM_COL32(135, 245, 255, 255);
        const ImU32 MessageColor = bError ? IM_COL32(255, 175, 185, 255)
                                 : bDone ? IM_COL32(170, 255, 215, 255)
                                         : IM_COL32(185, 238, 248, 255);
        const ImU32 RailColor = bError ? COL_RED : bDone ? COL_GREEN : IM_COL32(0, 195, 215, 255);

        const char* BadgeLabel = bError ? "ERR" : bDone ? "OK" : "INFO";
        const float TimeSize = 8.0f;
        const float BadgeTextSize = 7.8f;
        const float MessageSize = bNarrow ? 10.0f : 10.8f;
        const float LineHeight = bNarrow ? 12.0f : 13.0f;

        const float TimeW = bNarrow ? 48.0f : 56.0f;
        const float BadgeW = bNarrow ? 34.0f : 38.0f;
        const float BadgeH = 14.0f;
        const float MessageX = TimeW + BadgeW + (bNarrow ? 12.0f : 16.0f);
        const float MessageW = std::max(20.0f, Width - MessageX - 4.0f);

        std::string Message = TrimLog(Entry.text);
        if (Message.empty())
            Message = "(empty log entry)";

        const std::vector<std::string> Lines = WrapText(F, MessageSize, Message, MessageW);
        const float TextHeight = Lines.size() * LineHeight;
        const float Height = std::max(18.0f, TextHeight + 5.0f);

        /* left rail segment */
        DL->AddRectFilled(ImVec2(Pos.x - 5.0f, Pos.y), ImVec2(Pos.x - 3.0f, Pos.y + Height - 2.0f),
                          (RailColor & 0x00FFFFFF) | 0x55000000, 1.0f);

        /* timestamp */
        DL->AddText(F, TimeSize, ImVec2(Pos.x, Pos.y + 2.0f), COL_TEXT_DIM,
                    Entry.time.c_str());

        /* badge */
        const ImVec2 BadgePos(Pos.x + TimeW, Pos.y + 1.0f);
        DL->AddRectFilled(BadgePos, ImVec2(BadgePos.x + BadgeW, BadgePos.y + BadgeH), BadgeFill, 3.0f);
        DL->AddRect(BadgePos, ImVec2(BadgePos.x + BadgeW, BadgePos.y + BadgeH), BadgeBorder, 3.0f, 0, 1.0f);
        {
            const ImVec2 TextSize = F->CalcTextSizeA(BadgeTextSize, FLT_MAX, 0.0f, BadgeLabel);
            DL->AddText(F, BadgeTextSize,
                        ImVec2(BadgePos.x + (BadgeW - TextSize.x) * 0.5f,
                               BadgePos.y + (BadgeH - TextSize.y) * 0.5f),
                        BadgeText, BadgeLabel);
        }

        /* wrapped message */
        for (size_t i = 0; i < Lines.size(); ++i)
        {
            DL->AddText(F, MessageSize, ImVec2(Pos.x + MessageX, Pos.y + 1.0f + i * LineHeight),
                        MessageColor, Lines[i].c_str());
        }

        DL->AddLine(ImVec2(Pos.x, Pos.y + Height - 1.0f),
                    ImVec2(Pos.x + Width, Pos.y + Height - 1.0f),
                    IM_COL32(14, 45, 55, 90), 1.0f);

        return Height;
    }
}

/* ------------------------------------------------------------------------- */
/*  Main menu                                                                */
/* ------------------------------------------------------------------------- */
void UserMenu::RenderMenu()
{
    ImGuiIO& IO = ImGui::GetIO();
    Console& C = Console::Get();
    std::vector<Output> Logs = C.Snapshot();

    const float ScreenW = IO.DisplaySize.x;
    const float ScreenH = IO.DisplaySize.y;

    CGFloat SafeTop = 0.0;
    CGFloat SafeBottom = 0.0;
    if (@available(iOS 11.0, *))
    {
        UIWindow* Window = [UIApplication sharedApplication].windows.firstObject;
        if (Window)
        {
            SafeTop = Window.safeAreaInsets.top;
            SafeBottom = Window.safeAreaInsets.bottom;
        }
    }

    const float TopInset = std::max(8.0f, (float)SafeTop + 4.0f);
    const float BottomInset = std::max(8.0f, (float)SafeBottom + 4.0f);
    const float W = std::max(220.0f, std::min(620.0f, ScreenW - 12.0f));
    const float H = std::max(200.0f, std::min(760.0f, ScreenH - TopInset - BottomInset));
    const ImVec2 WinPos(std::max(6.0f, (ScreenW - W) * 0.5f), TopInset);

    const bool bCompact = H < 470.0f;
    const float Pad = 10.0f;
    const float HeaderH = bCompact ? 60.0f : 68.0f;
    const float CardH = bCompact ? 42.0f : 48.0f;
    const float BtnH = bCompact ? 28.0f : 32.0f;
    const float FooterH = 26.0f;
    const float CardGap = 8.0f;
    const float ToolGap = 6.0f;

    ImGui::SetNextWindowPos(WinPos, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(W, H), ImGuiCond_Always);

    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 12.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0.0f, 0.0f));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 5.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_ChildBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 0.0f);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.012f, 0.035f, 0.055f, 0.96f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.0f, 0.55f, 0.58f, 0.55f));
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.65f, 0.94f, 1.0f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
    ImGui::PushStyleColor(ImGuiCol_ScrollbarBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
    ImGui::PushStyleColor(ImGuiCol_ScrollbarGrab, ImVec4(0.0f, 0.55f, 0.60f, 0.55f));
    ImGui::PushStyleColor(ImGuiCol_ScrollbarGrabHovered, ImVec4(0.0f, 0.75f, 0.80f, 0.75f));
    ImGui::PushStyleColor(ImGuiCol_ScrollbarGrabActive, ImVec4(0.0f, 0.90f, 0.95f, 0.90f));

    const ImGuiWindowFlags Flags = ImGuiWindowFlags_NoTitleBar |
                                   ImGuiWindowFlags_NoResize |
                                   ImGuiWindowFlags_NoScrollbar |
                                   ImGuiWindowFlags_NoScrollWithMouse |
                                   ImGuiWindowFlags_NoCollapse;

    bool bHideMenu = false;

    if (ImGui::Begin("##CHUNMOD_HUD", nullptr, Flags))
    {
        const ImVec2 WP = ImGui::GetWindowPos();
        const ImVec2 WS = ImGui::GetWindowSize();
        ImDrawList* DL = ImGui::GetWindowDrawList();
        ImFont* F = ImGui::GetFont();

        /* ---- background / header band ---------------------------------- */
        DL->AddRectFilled(WP, ImVec2(WP.x + WS.x, WP.y + HeaderH), COL_HEADER, 12.0f,
                          ImDrawFlags_RoundCornersTop);
        DL->AddLine(ImVec2(WP.x + 12.0f, WP.y + HeaderH),
                    ImVec2(WP.x + WS.x - 12.0f, WP.y + HeaderH), COL_DIVIDER, 1.0f);

        /* ---- flexible header ------------------------------------------- */
        const float LogoSize = (bCompact || WS.x < 360.0f) ? 32.0f : 38.0f;
        const float LogoX = Pad;
        const float LogoY = bCompact ? 8.0f : 10.0f;
        const ImVec2 LogoP0(WP.x + LogoX, WP.y + LogoY);
        const ImVec2 LogoP1(LogoP0.x + LogoSize, LogoP0.y + LogoSize);

        DL->AddRectFilled(ImVec2(LogoP0.x - 2.0f, LogoP0.y - 2.0f),
                          ImVec2(LogoP1.x + 2.0f, LogoP1.y + 2.0f),
                          IM_COL32(0, 120, 132, 32), 9.0f);
        DL->AddRectFilled(LogoP0, LogoP1, IM_COL32(7, 31, 40, 255), 7.0f);
        DL->AddRect(LogoP0, LogoP1, COL_ACCENT_DIM, 7.0f, 0, 1.0f);
        DrawIcon(DL, HudIcon::Bolt,
                 ImVec2((LogoP0.x + LogoP1.x) * 0.5f, (LogoP0.y + LogoP1.y) * 0.5f),
                 LogoSize * 0.58f, COL_ACCENT);

        const float TitleX = LogoX + LogoSize + 10.0f;
        const float TitleY = LogoY + (bCompact ? 0.0f : 1.0f);
        float TitleSize = bCompact ? 13.0f : 14.5f;
        if (WS.x < 420.0f)
            TitleSize = 13.5f;
        if (WS.x < 360.0f)
            TitleSize = 12.0f;
        if (WS.x < 330.0f)
            TitleSize = 11.0f;

        const float CtrlSize = 24.0f;
        const float CtrlGap = 4.0f;
        const float TitleLimit = WS.x - Pad - CtrlSize * 2.0f - CtrlGap - 8.0f;
        const float TitleAvail = std::max(0.0f, TitleLimit - TitleX);

        const std::string TitleA = "IOS SDK DUMPER";
        const std::string TitleB = " // ";
        const std::string TitleC = "CHUNMOD-Dumper";

        std::string PartA = TitleA;
        std::string PartB = TitleB;
        std::string PartC = TitleC;
        const float WidthAB = TextWidth(F, TitleSize, TitleA + TitleB);
        if (WidthAB + TextWidth(F, TitleSize, TitleC) > TitleAvail)
        {
            if (WidthAB <= TitleAvail)
            {
                PartC = Ellipsize(F, TitleSize, TitleC, TitleAvail - WidthAB);
            }
            else
            {
                PartB.clear();
                PartC.clear();
                PartA = Ellipsize(F, TitleSize, TitleA, TitleAvail);
            }
        }

        float TitleCursor = WP.x + TitleX;
        DrawBoldText(DL, F, TitleSize, ImVec2(TitleCursor, WP.y + TitleY), COL_TEXT, PartA);
        TitleCursor += TextWidth(F, TitleSize, PartA);
        DrawText(DL, F, TitleSize, ImVec2(TitleCursor, WP.y + TitleY), COL_TEXT_SOFT, PartB);
        TitleCursor += TextWidth(F, TitleSize, PartB);
        DrawText(DL, F, TitleSize, ImVec2(TitleCursor, WP.y + TitleY), COL_ACCENT, PartC);

        /* window controls */
        const float CloseX = WS.x - Pad - CtrlSize;
        ImGui::SetCursorScreenPos(ImVec2(WP.x + CloseX, WP.y + LogoY));
        if (HudWindowButton("close", HudIcon::Close, true))
            bHideMenu = true;
        ImGui::SetCursorScreenPos(ImVec2(WP.x + CloseX - CtrlGap - CtrlSize, WP.y + LogoY));
        if (HudWindowButton("min", HudIcon::Minus, false))
            bHideMenu = true;

        /* status + rec pills */
        const bool bRunning = GDumpRunning.load();
        const bool bHasRun = GHasRun.load();
        const std::string StatusLabel = bRunning ? "RUNNING"
                                     : bHasRun ? "DONE / IDLE"
                                               : "READY / IDLE";
        const ImU32 StatusColor = bRunning ? COL_AMBER : bHasRun ? COL_GREEN : COL_ACCENT;
        const float StatusW = 100.0f;
        const float StatusX = WS.x - Pad - StatusW;
        const float StatusY = HeaderH - 26.0f;
        DrawStatusPill(DL, F, ImVec2(WP.x + StatusX, WP.y + StatusY), StatusW,
                       StatusLabel, StatusColor, bRunning);

        const float RecW = 72.0f;
        const float RecX = StatusX - 8.0f - RecW;
        if (RecX > Pad)
        {
            ImGui::SetCursorScreenPos(ImVec2(WP.x + RecX, WP.y + StatusY));
            ImGui::InvisibleButton("##rec", ImVec2(RecW, 20.0f));
            if (ImGui::IsItemClicked())
                GRecVisible = !GRecVisible;
            DrawRecPill(DL, F, ImVec2(WP.x + RecX, WP.y + StatusY), RecW, GRecVisible);
        }

        /* subtitle beneath the title */
        const std::string Subtitle = "GAMING HUD EDITION  |  CRE @CHUNMODVN";
        const float SubSize = 8.2f;
        const float SubtitleMaxW = std::max(20.0f, WS.x - Pad - TitleX);
        DrawText(DL, F, SubSize,
                 ImVec2(WP.x + TitleX, WP.y + TitleY + TitleSize + 2.0f),
                 COL_VIOLET, Ellipsize(F, SubSize, Subtitle, SubtitleMaxW));

        /* ---- telemetry cards ------------------------------------------- */
        const float CardsY = HeaderH + 8.0f;
        const float CardW = (WS.x - Pad * 2.0f - CardGap * 2.0f) / 3.0f;
        const BundleMetadata& Bundle = GetBundleMetadata();

        std::string TargetName = Bundle.Name;
        if (TargetName.empty())
            TargetName = "AWAITING TARGET";
        std::string TargetVersion = Bundle.Version;
        std::string TargetValue = TargetName;
        if (!TargetVersion.empty())
            TargetValue += " " + TargetVersion;

        char UeVersion[16];
        std::snprintf(UeVersion, sizeof(UeVersion), "UE %d.%02d", UEVERSION / 100, UEVERSION % 100);
        const std::string ArchValue = std::string("ARM64  |  ") + UeVersion;

        size_t CountAll = Logs.size();
        size_t CountOk = 0;
        size_t CountErr = 0;
        for (const Output& Entry : Logs)
        {
            if (Entry.type == 2) ++CountOk;
            if (Entry.type == 1) ++CountErr;
        }

        const float CardLabelSize = 7.6f;
        const float CardValueSize = bCompact ? 9.5f : 10.6f;
        const float CardInnerX = 8.0f;
        const float CardInnerW = CardW - CardInnerX * 2.0f;

        auto DrawCardFrame = [&](float X, const char* Label)
        {
            const ImVec2 P0(WP.x + X, WP.y + CardsY);
            const ImVec2 P1(P0.x + CardW, P0.y + CardH);
            DL->AddRectFilled(P0, P1, COL_PANEL, 6.0f);
            DL->AddRect(P0, P1, COL_BORDER_SOFT, 6.0f, 0, 1.0f);
            DL->AddRectFilled(ImVec2(P0.x + 1.0f, P0.y + 1.0f),
                              ImVec2(P0.x + 3.0f, P0.y + CardH * 0.45f),
                              COL_ACCENT_DIM, 1.0f);
            DL->AddText(F, CardLabelSize, ImVec2(P0.x + CardInnerX, P0.y + (bCompact ? 6.0f : 8.0f)),
                        COL_LABEL, Ellipsize(F, CardLabelSize, Label, CardInnerW).c_str());
            return P0;
        };

        ImVec2 Card0 = DrawCardFrame(Pad, "TARGET APPLICATION");
        ImVec2 Card1 = DrawCardFrame(Pad + CardW + CardGap, "RUNTIME ARCHITECTURE");
        ImVec2 Card2 = DrawCardFrame(Pad + (CardW + CardGap) * 2.0f, "CONSOLE TELEMETRY");

        const float CardValueY = bCompact ? 20.0f : 24.0f;
        DrawText(DL, F, CardValueSize, ImVec2(Card0.x + CardInnerX, Card0.y + CardValueY), COL_TEXT,
                 Ellipsize(F, CardValueSize, TargetValue, CardInnerW));
        DrawText(DL, F, CardValueSize, ImVec2(Card1.x + CardInnerX, Card1.y + CardValueY), COL_TEXT,
                 Ellipsize(F, CardValueSize, ArchValue, CardInnerW));

        /* telemetry value: ALL / OK / ERR with colored numbers */
        {
            char AllBuf[24];
            char OkBuf[24];
            char ErrBuf[24];
            std::snprintf(AllBuf, sizeof(AllBuf), "%zu", CountAll);
            std::snprintf(OkBuf, sizeof(OkBuf), "%zu", CountOk);
            std::snprintf(ErrBuf, sizeof(ErrBuf), "%zu", CountErr);

            float Size = bCompact ? 8.5f : 9.5f;
            const std::string Line = std::string("ALL:") + AllBuf + "  OK:" + OkBuf + "  ERR:" + ErrBuf;
            if (TextWidth(F, Size, Line) > CardInnerW)
                Size = 7.8f;

            if (TextWidth(F, Size, Line) <= CardInnerW)
            {
                float X = Card2.x + CardInnerX;
                const float Y = Card2.y + CardValueY;
                auto Segment = [&](const char* Label, const char* Value, ImU32 ValueColor)
                {
                    DrawText(DL, F, Size, ImVec2(X, Y), COL_TEXT_DIM, Label);
                    X += TextWidth(F, Size, Label);
                    DrawText(DL, F, Size, ImVec2(X, Y), ValueColor, Value);
                    X += TextWidth(F, Size, Value) + 6.0f;
                };
                Segment("ALL:", AllBuf, COL_TEXT);
                Segment("OK:", OkBuf, COL_GREEN);
                Segment("ERR:", ErrBuf, CountErr ? COL_RED : COL_TEXT_SOFT);
            }
            else
            {
                /* very narrow card: numbers only */
                const std::string Compact = std::string(AllBuf) + " / " + OkBuf + " / " + ErrBuf;
                DrawText(DL, F, Size, ImVec2(Card2.x + CardInnerX, Card2.y + CardValueY), COL_TEXT,
                         Ellipsize(F, Size, Compact, CardInnerW));
            }
        }

        /* ---- toolbar ---------------------------------------------------- */
        const float ToolbarY = CardsY + CardH + 8.0f;
        const float StartW = bCompact ? 118.0f : 132.0f;
        const float CopyW = bCompact ? 56.0f : 62.0f;
        const float ClearW = bCompact ? 58.0f : 64.0f;
        const float AutoW = bCompact ? 88.0f : 96.0f;
        const float FilterW = bCompact ? 38.0f : 42.0f;
        const float FilterGap = 5.0f;
        const float FiltersW = FilterW * 4.0f + FilterGap * 3.0f;
        const float NeededW = StartW + CopyW + ClearW + AutoW + FiltersW + ToolGap * 5.0f;
        const bool bSingleRow = (WS.x - Pad * 2.0f) >= NeededW;

        float ToolbarBottom = ToolbarY + BtnH;
        bool bClearPressed = false;

        if (bSingleRow)
        {
            float X = Pad;

            ImGui::SetCursorScreenPos(ImVec2(WP.x + X, WP.y + ToolbarY));
            if (HudButton("start", bRunning ? "DUMPING..." : "START DUMP",
                          ImVec2(StartW, BtnH), HudIcon::Bolt, true, false, !bRunning, COL_ACCENT))
            {
                bool Expected = false;
                if (GDumpRunning.compare_exchange_strong(Expected, true))
                {
                    GHasRun = false;
                    std::thread([] {
                        try { StartDump(); } catch (...) {}
                        GHasRun = true;
                        GDumpRunning = false;
                    }).detach();
                }
            }
            X += StartW + ToolGap;

            ImGui::SetCursorScreenPos(ImVec2(WP.x + X, WP.y + ToolbarY));
            if (HudButton("copy", "COPY", ImVec2(CopyW, BtnH), HudIcon::Copy,
                          false, false, true, COL_ACCENT))
            {
                CopyLogsToClipboard(Logs);
            }
            X += CopyW + ToolGap;

            ImGui::SetCursorScreenPos(ImVec2(WP.x + X, WP.y + ToolbarY));
            if (HudButton("clear", "CLEAR", ImVec2(ClearW, BtnH), HudIcon::Trash,
                          false, false, true, COL_ACCENT))
            {
                bClearPressed = true;
            }
            X += ClearW + ToolGap;

            ImGui::SetCursorScreenPos(ImVec2(WP.x + X, WP.y + ToolbarY));
            if (HudButton("auto", C.autoScroll ? "AUTO: ON" : "AUTO: OFF",
                          ImVec2(AutoW, BtnH), HudIcon::Power,
                          false, C.autoScroll, true, COL_GREEN))
            {
                C.autoScroll = !C.autoScroll;
            }

            const float FX = WS.x - Pad - FiltersW;
            const char* Labels[4] = { "ALL", "INFO", "OK", "ERR" };
            const int Values[4] = { -1, 0, 2, 1 };
            for (int i = 0; i < 4; ++i)
            {
                ImGui::SetCursorScreenPos(ImVec2(WP.x + FX + i * (FilterW + FilterGap), WP.y + ToolbarY));
                if (HudButton(Labels[i], Labels[i], ImVec2(FilterW, BtnH), HudIcon::None,
                              false, C.filter == Values[i], true, COL_ACCENT))
                {
                    C.filter = Values[i];
                }
            }
        }
        else
        {
            const float Row1Y = ToolbarY;
            const float Row2Y = ToolbarY + BtnH + 6.0f;
            ToolbarBottom = Row2Y + BtnH;

            const float StretchStartW = std::max(70.0f,
                WS.x - Pad * 2.0f - CopyW - ClearW - ToolGap * 2.0f);
            float X = Pad;

            ImGui::SetCursorScreenPos(ImVec2(WP.x + X, WP.y + Row1Y));
            if (HudButton("start", bRunning ? "DUMPING..." : "START DUMP",
                          ImVec2(StretchStartW, BtnH), HudIcon::Bolt, true, false, !bRunning, COL_ACCENT))
            {
                bool Expected = false;
                if (GDumpRunning.compare_exchange_strong(Expected, true))
                {
                    GHasRun = false;
                    std::thread([] {
                        try { StartDump(); } catch (...) {}
                        GHasRun = true;
                        GDumpRunning = false;
                    }).detach();
                }
            }
            X += StretchStartW + ToolGap;

            ImGui::SetCursorScreenPos(ImVec2(WP.x + X, WP.y + Row1Y));
            if (HudButton("copy", "COPY", ImVec2(CopyW, BtnH), HudIcon::Copy,
                          false, false, true, COL_ACCENT))
            {
                CopyLogsToClipboard(Logs);
            }
            X += CopyW + ToolGap;

            ImGui::SetCursorScreenPos(ImVec2(WP.x + X, WP.y + Row1Y));
            if (HudButton("clear", "CLEAR", ImVec2(ClearW, BtnH), HudIcon::Trash,
                          false, false, true, COL_ACCENT))
            {
                bClearPressed = true;
            }

            ImGui::SetCursorScreenPos(ImVec2(WP.x + Pad, WP.y + Row2Y));
            if (HudButton("auto", C.autoScroll ? "AUTO: ON" : "AUTO: OFF",
                          ImVec2(AutoW, BtnH), HudIcon::Power,
                          false, C.autoScroll, true, COL_GREEN))
            {
                C.autoScroll = !C.autoScroll;
            }

            float Row2FilterW = (WS.x - Pad * 2.0f - AutoW - ToolGap - FilterGap * 3.0f) / 4.0f;
            Row2FilterW = std::max(26.0f, std::min(FilterW, Row2FilterW));
            const float Row2FiltersW = Row2FilterW * 4.0f + FilterGap * 3.0f;
            const float FX2 = WS.x - Pad - Row2FiltersW;
            const char* Labels[4] = { "ALL", "INFO", "OK", "ERR" };
            const int Values[4] = { -1, 0, 2, 1 };
            for (int i = 0; i < 4; ++i)
            {
                ImGui::SetCursorScreenPos(ImVec2(WP.x + FX2 + i * (Row2FilterW + FilterGap), WP.y + Row2Y));
                if (HudButton(Labels[i], Labels[i], ImVec2(Row2FilterW, BtnH), HudIcon::None,
                              false, C.filter == Values[i], true, COL_ACCENT))
                {
                    C.filter = Values[i];
                }
            }
        }

        if (bClearPressed)
        {
            C.clearLogs();
            Logs.clear();
            CountAll = 0;
            CountOk = 0;
            CountErr = 0;
        }

        /* ---- console ---------------------------------------------------- */
        const float ConsoleX = Pad;
        const float ConsoleY = ToolbarBottom + 8.0f;
        const float ConsoleW = WS.x - Pad * 2.0f;
        const float ConsoleH = std::max(30.0f, WS.y - FooterH - 3.0f - ConsoleY);
        const ImVec2 CP0(WP.x + ConsoleX, WP.y + ConsoleY);
        const ImVec2 CP1(CP0.x + ConsoleW, CP0.y + std::max(30.0f, ConsoleH));

        DL->AddRectFilled(CP0, CP1, COL_CONSOLE, 8.0f);
        DL->AddRect(CP0, CP1, COL_BORDER_SOFT, 8.0f, 0, 1.0f);
        DL->AddLine(ImVec2(CP0.x + 10.0f, CP0.y + 0.5f),
                    ImVec2(CP1.x - 10.0f, CP0.y + 0.5f), IM_COL32(0, 120, 135, 70), 1.0f);
        if (ConsoleH > 44.0f)
        {
            DL->AddRectFilled(ImVec2(CP0.x + 3.0f, CP0.y + 9.0f),
                              ImVec2(CP0.x + 5.0f, CP1.y - 9.0f),
                              IM_COL32(0, 165, 180, 110), 1.0f);
        }

        const float ConsoleInnerX = 8.0f;
        const float ConsoleInnerY = 8.0f;
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(ConsoleInnerX, ConsoleInnerY));
        ImGui::PushStyleVar(ImGuiStyleVar_ScrollbarSize, 5.0f);

        ImGui::SetCursorScreenPos(ImVec2(CP0.x + 2.0f, CP0.y + 2.0f));
        ImGui::BeginChild("##ConsoleScroll", ImVec2(ConsoleW - 4.0f, std::max(24.0f, ConsoleH - 4.0f)),
                          false, ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoMove);

        ImDrawList* CDL = ImGui::GetWindowDrawList();
        const float ContentW = ImGui::GetContentRegionAvail().x;
        const bool bNarrowLogs = ContentW < 330.0f;

        /* Touch input has no mouse wheel, so dragging the console scrolls it. */
        static bool GConsoleDragging = false;
        static float GConsoleDragY = 0.0f;
        bool bDraggingConsole = false;

        if (ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem) &&
            ImGui::IsMouseClicked(ImGuiMouseButton_Left) &&
            IO.MousePos.x < ImGui::GetWindowPos().x + ImGui::GetWindowSize().x - 8.0f)
        {
            GConsoleDragging = true;
            GConsoleDragY = IO.MousePos.y;
            bDraggingConsole = true;
        }

        if (GConsoleDragging)
        {
            if (ImGui::IsMouseDown(ImGuiMouseButton_Left))
            {
                bDraggingConsole = true;
                const float DeltaY = IO.MousePos.y - GConsoleDragY;
                if (std::fabs(DeltaY) >= 0.5f)
                {
                    ImGui::SetScrollY(ImGui::GetScrollY() - DeltaY);
                    GConsoleDragY = IO.MousePos.y;
                    if (std::fabs(DeltaY) > 1.5f)
                        C.autoScroll = false;
                }
            }
            else
            {
                GConsoleDragging = false;
            }
        }

        int VisibleRows = 0;
        for (const Output& Entry : Logs)
        {
            if (C.filter != -1 && Entry.type != C.filter)
                continue;

            const ImVec2 RowPos = ImGui::GetCursorScreenPos();
            const float RowH = DrawLogRow(CDL, F, RowPos, ContentW, Entry, bNarrowLogs);

            ImGui::SetCursorScreenPos(RowPos);
            ImGui::Dummy(ImVec2(ContentW, RowH));
            ++VisibleRows;
        }

        if (VisibleRows == 0)
        {
            const char* EmptyText = "NO TELEMETRY YET";
            const char* EmptyHint = "PRESS START DUMP TO BEGIN";
            const float EmptySize = bNarrowLogs ? 9.0f : 10.0f;
            const float CenterY = std::max(10.0f, (ConsoleH - 40.0f) * 0.45f);
            const float T1W = TextWidth(F, EmptySize, EmptyText);
            const float T2W = TextWidth(F, EmptySize * 0.85f, EmptyHint);
            DrawText(CDL, F, EmptySize,
                     ImVec2(CP0.x + 8.0f + (ContentW - T1W) * 0.5f, CP0.y + CenterY),
                     COL_TEXT_SOFT, EmptyText);
            DrawText(CDL, F, EmptySize * 0.85f,
                     ImVec2(CP0.x + 8.0f + (ContentW - T2W) * 0.5f, CP0.y + CenterY + 15.0f),
                     IM_COL32(35, 80, 92, 255), EmptyHint);
            ImGui::Dummy(ImVec2(ContentW, std::max(20.0f, ConsoleH - 16.0f)));
        }

        if (C.autoScroll && !bDraggingConsole)
            ImGui::SetScrollHereY(1.0f);

        ImGui::EndChild();
        ImGui::PopStyleVar(2);

        /* ---- footer ----------------------------------------------------- */
        const float FooterY = WS.y - FooterH;
        DL->AddLine(ImVec2(WP.x + Pad, WP.y + FooterY),
                    ImVec2(WP.x + WS.x - Pad, WP.y + FooterY), COL_DIVIDER, 1.0f);

        const float FooterCy = WP.y + FooterY + FooterH * 0.5f;
        DrawIcon(DL, HudIcon::Folder, ImVec2(WP.x + Pad + 6.0f, FooterCy), 9.0f, COL_ACCENT_DIM);

        const float CreditSize = 8.4f;
        const std::string Credit = "CRE: @CHUNMODVN";
        const float CreditW = TextWidth(F, CreditSize, Credit);
        const float CreditX = WS.x - Pad - CreditW - 18.0f;
        const float PathX = WP.x + Pad + 18.0f;
        const float PathW = std::max(20.0f, CreditX - PathX - 10.0f);
        const std::string Path = GetFooterPath(bRunning);
        DrawText(DL, F, 8.4f, ImVec2(PathX, FooterCy - 5.0f), COL_TEXT_DIM,
                 Ellipsize(F, 8.4f, Path, PathW));

        DrawText(DL, F, CreditSize, ImVec2(CreditX, FooterCy - 5.0f), COL_ACCENT, Credit);
        DrawIcon(DL, HudIcon::Bolt, ImVec2(WP.x + WS.x - Pad - 4.0f, FooterCy), 9.0f, COL_ACCENT);
    }

    ImGui::End();

    ImGui::PopStyleColor(8);
    ImGui::PopStyleVar(7);

    if (bHideMenu)
        [ImGuiDrawView showChange:NO];
}
