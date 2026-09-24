import SwiftUI

/// A verified group's avatar: its custom image, otherwise two overlapping member avatars
/// (spec §30 "generated/custom avatar").
struct GroupAvatarView: View {
    let avatarURL: String?
    let seed: String
    let initials: String
    let members: [GroupMember]
    let size: CGFloat

    var body: some View {
        if avatarURL?.nonEmptyTrimmed != nil || members.count < 2 {
            AvatarView(imageURL: avatarURL, seed: seed, initials: initials, size: size)
        } else {
            let small = size * 0.7
            ZStack(alignment: .topLeading) {
                AvatarView(imageURL: members[1].avatarURL, seed: members[1].userID, initials: members[1].initials, size: small)
                    .offset(x: size - small, y: size - small)
                AvatarView(imageURL: members[0].avatarURL, seed: members[0].userID, initials: members[0].initials, size: small)
                    .overlay(Circle().stroke(ClickColors.background, lineWidth: 2))
            }
            .frame(width: size, height: size, alignment: .topLeading)
            .accessibilityHidden(true)
        }
    }
}

extension CliqueItem {
    /// Members other than the viewer first, so the generated avatar shows other people.
    func avatarMembers(excluding userID: String?) -> [GroupMember] {
        members.filter { $0.userID != userID } + members.filter { $0.userID == userID }
    }
}
