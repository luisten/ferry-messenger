import SwiftUI

/// T3 chat info, minimal (DESIGN T3): who the chat is with, which of your accounts it belongs to, their Instagram
/// profile when the handle is known (one of our accounts, or the ghost profile's identifiers), a group's members, and
/// Archive. Not in v1: mute, search in chat, shared media, delete, actions on members.
struct ChatInfoView: View {
    @Environment(AppModel.self) private var model
    let roomID: String
    @State private var archived = 0
    @State private var person: Inbox.Member?

    var body: some View {
        if let room = model.room(roomID) {
            content(room)
        } else {
            ContentUnavailableView("Chat not found", systemImage: "text.bubble")
        }
    }

    private func content(_ room: Room) -> some View {
        let receiver = room.bridge?.receiver
        let identity = receiver.flatMap { model.identities[$0] }
        let login = receiver.flatMap { id in model.accounts.first { $0.id == id } }
        let handle = model.contactHandle(of: room)
        let folder = Inbox.folder(of: room)
        let isGroup = room.bridge?.roomType == .group
        // The thread's start block says the same: "4 members", "@handle".
        let count = Inbox.memberCount(of: room)
        let subtitle = Inbox.startBlock(isGroup: isGroup, members: count, handle: handle, account: nil, isEmpty: false).subtitle
        return Form {
            Section {
                VStack(spacing: 6) {
                    RoomAvatar(room: room, size: 88).padding(.bottom, 6)
                        .environment(\.markRing, Color(.systemGroupedBackground))  // on the page, not on a row
                    Text(room.name).font(.title2.bold()).multilineTextAlignment(.center)
                    if let subtitle { Text(subtitle).foregroundStyle(.inkSecondary) }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            if let identity {
                Section {
                    // "Account", not "In [tag]" (review 2026-10-15 #6); the handle when it fits.
                    LabeledContent("Account") {
                        ViewThatFits(in: .horizontal) {
                            AccountTag(identity: identity, handle: login?.profile?.username)
                            AccountTag(identity: identity)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("info.account")
                    if folder == .general {
                        LabeledContent("Folder", value: "General").accessibilityIdentifier("info.folder")
                    }
                } footer: {
                    Text("Replies always come from this account.")
                }
            }
            if isGroup { members(room, identity: identity, login: login) }
            if let handle, let url = URL(string: "https://www.instagram.com/\(handle)/") {
                Section {
                    Link(destination: url) {
                        HStack {  // not a Label: in a List its icon takes the wide icon column
                            Text("Open in Instagram")
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.inkSecondary)
                        }
                    }
                    .accessibilityIdentifier("info.openInInstagram")
                }
            }
            if folder != .requests {  // requests stay in Requests; archiving one would do nothing
                Section {
                    Button(folder == .archived ? "Unarchive Chat" : "Archive Chat") {
                        archived += 1
                        model.setArchived(folder != .archived, room)
                    }
                    .accessibilityIdentifier("info.archive")
                } footer: {
                    Text(folder == .archived ? "It's in Archived. A new message brings it back by itself."
                         : "Archived chats come back when there's a new message. Instagram isn't changed.")
                }
            }
        }
        .navigationTitle("Chat Info")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.markRing, Color(.secondarySystemGroupedBackground))
        .sensoryFeedback(.impact(weight: .medium), trigger: archived)
        .sheet(item: $person) { PersonCard(name: $0.name, handle: $0.handle, avatarURL: $0.avatarURL) }
    }

    /// Read-only (DESIGN T3; no member actions yet): a tap shows who someone is. Everyone comes with the thread, so
    /// nothing loads here.
    @ViewBuilder
    private func members(_ room: Room, identity: AccountIdentity?, login: BridgeAPI.Login?) -> some View {
        let members = Inbox.members(of: room, me: model.me, profiles: model.profiles)
        Section {
            ForEach(members) { member in
                if member.isMe {
                    MemberRow(member: member, identity: identity, login: login)
                } else {
                    Button { person = member } label: { MemberRow(member: member, identity: identity, login: login) }
                        .foregroundStyle(Color.primary)  // not the tint
                        .accessibilityHint("Shows who they are")
                }
            }
        } header: {
            Text("\(members.count) \(members.count == 1 ? "Member" : "Members")")
                .accessibilityIdentifier("info.membersHeader")
        } footer: {
            Text("To add or remove people, use Instagram.")
        }
    }
}

/// One member: avatar, name and @handle when their ghost profile has it. We're "You" with our account's avatar and
/// mark (colour means account).
private struct MemberRow: View {
    let member: Inbox.Member
    let identity: AccountIdentity?
    let login: BridgeAPI.Login?

    var body: some View {
        let handle = member.isMe ? login?.profile?.username : member.handle
        HStack(spacing: 12) {
            if member.isMe {
                AccountAvatar(identity: identity, avatarURL: login?.profile?.avatar, initial: login?.displayName ?? "", size: 36)
            } else {
                MXCImage(mxc: member.avatarURL, size: 36, initial: member.name)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                if let handle { Text("@\(handle)").font(.subheadline).foregroundStyle(.inkSecondary) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([member.isMe ? identity.map { "You, \($0.name) account" } ?? "You" : member.name,
                             handle.map { "@\($0)" }].compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("info.member")
    }
}

/// Who someone is, bigger than a 28 pt face (a tap on their picture in a group, or on a member in Chat Info): their
/// picture, name, @handle and Instagram profile. Only what the thread brought: nothing is asked of Instagram.
struct PersonCard: View {
    let name: String
    let handle: String?
    let avatarURL: String?

    var body: some View {
        VStack(spacing: 6) {
            // ponytail: the thread's picture is Instagram's small one (150 px), soft at this size; a bigger one costs a
            // profile request per tap.
            MXCImage(mxc: avatarURL, size: 120, initial: name).padding(.bottom, 10)
            Text(name).font(.title2.bold()).multilineTextAlignment(.center)
            if let handle { Text("@\(handle)").foregroundStyle(.inkSecondary) }
            if let url = handle.flatMap({ URL(string: "https://www.instagram.com/\($0)/") }) {
                Link(destination: url) { Label("Open in Instagram", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.glass)
                    .padding(.top, 14)
                    .accessibilityIdentifier("person.openInInstagram")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .accessibilityIdentifier("person.card")
    }
}
