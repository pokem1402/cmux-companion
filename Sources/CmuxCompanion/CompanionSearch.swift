import Foundation
import CmuxCompanionCore

struct CompanionSearchResults {
    let sets: [WorkSet]
    let unlinkedSurfaces: [LiveSurface]
    let matchingSetIDs: Set<UUID>
    let matchingUnlinkedSurfaceIDs: Set<String>
    let isActive: Bool
    let hasAnyMatch: Bool
}

enum CompanionSearch {
    static func results(
        sets: [WorkSet],
        unlinkedSurfaces: [LiveSurface],
        allLiveSurfaces: [LiveSurface],
        query: String
    ) -> CompanionSearchResults {
        let tokens = normalizedTokens(query)
        guard !tokens.isEmpty else {
            return CompanionSearchResults(
                sets: sets,
                unlinkedSurfaces: unlinkedSurfaces,
                matchingSetIDs: Set(sets.map(\.id)),
                matchingUnlinkedSurfaceIDs: Set(unlinkedSurfaces.map(\.id)),
                isActive: false,
                hasAnyMatch: true
            )
        }

        let matchingSets = sets.filter {
            matches(set: $0, liveSurfaces: allLiveSurfaces, tokens: tokens)
        }
        let matchingSurfaces = unlinkedSurfaces.filter {
            matches(surface: $0, tokens: tokens)
        }
        let hasAnyMatch = !matchingSets.isEmpty || !matchingSurfaces.isEmpty
        let matchingSetIDs = Set(matchingSets.map(\.id))
        let orderedSets = matchingSets + sets.filter { !matchingSetIDs.contains($0.id) }

        // Every set remains visible during a successful search because linked
        // members can be dragged from any source set to any destination set.
        // Matches move to the top and are highlighted/expanded by the view.
        // The unlinked tray can still narrow to matching source terminals.
        return CompanionSearchResults(
            sets: hasAnyMatch ? orderedSets : [],
            unlinkedSurfaces: matchingSurfaces.isEmpty && !matchingSets.isEmpty
                ? unlinkedSurfaces
                : matchingSurfaces,
            matchingSetIDs: matchingSetIDs,
            matchingUnlinkedSurfaceIDs: Set(matchingSurfaces.map(\.id)),
            isActive: true,
            hasAnyMatch: hasAnyMatch
        )
    }

    static func matches(surface: LiveSurface, query: String) -> Bool {
        matches(surface: surface, tokens: normalizedTokens(query))
    }

    static func matches(
        set: WorkSet,
        liveSurfaces: [LiveSurface],
        query: String
    ) -> Bool {
        matches(set: set, liveSurfaces: liveSurfaces, tokens: normalizedTokens(query))
    }

    private static func matches(surface: LiveSurface, tokens: [String]) -> Bool {
        matches(tokens: tokens, values: [
            surface.displayTitle,
            surface.title,
            surface.ref,
            surface.workspaceTitle,
            surface.agent,
            surface.workload.displayName,
            surface.sessionID,
        ])
    }

    private static func matches(
        set: WorkSet,
        liveSurfaces: [LiveSurface],
        tokens: [String]
    ) -> Bool {
        var values: [String?] = [set.label]
        values.append(contentsOf: set.groups.flatMap { group in
            [group.label, group.role?.rawValue]
        })
        values.append(contentsOf: set.members.flatMap { member in
            [member.label, member.agent, member.sessionID, member.workspaceID]
        })
        values.append(contentsOf: set.attachments.flatMap { attachment in
            [attachment.label, attachment.url?.host, attachment.url?.absoluteString]
        })

        let memberSurfaceIDs = Set(set.members.compactMap(\.surfaceID))
        let memberSessionIDs = Set(set.members.compactMap(\.sessionID))
        let attachmentSurfaceIDs = Set(set.attachments.compactMap(\.surfaceID))
        for surface in liveSurfaces where memberSurfaceIDs.contains(surface.id)
            || surface.ref.map(memberSurfaceIDs.contains) == true
            || surface.sessionID.map(memberSessionIDs.contains) == true
            || attachmentSurfaceIDs.contains(surface.id)
            || surface.ref.map(attachmentSurfaceIDs.contains) == true {
            values.append(contentsOf: [
                surface.displayTitle,
                surface.title,
                surface.workspaceTitle,
                surface.agent,
                surface.workload.displayName,
            ])
        }
        return matches(tokens: tokens, values: values)
    }

    private static func matches(tokens: [String], values: [String?]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = values.compactMap { $0 }.map(normalized).joined(separator: "\n")
        return tokens.allSatisfy(haystack.contains)
    }

    private static func normalizedTokens(_ query: String) -> [String] {
        normalized(query)
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .lowercased()
    }
}
