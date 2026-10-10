# InView Photon integration plan

**Recommended feature: an AI access agent that arranges the human assistance needed to complete a route.** InView contacts the appropriate building staff through Photon, handles their responses, and updates the visitor's AR journey when assistance is ready.

> InView can arrange the help your route needs, then guide you through.

This is the final recommendation from [InView Navigation Planning](chatgpt-conversation://6ac9d70f-5040-83e9-beb5-8a8e479a1b5d), following the discussion of meeting coordination and shared links. It extends the navigation plan in [larp.md](larp.md); implementation and teammate ownership still need to be agreed.

## Why Photon has a necessary role

Some physically suitable routes require a person to act: an attendant must operate a lift, or someone must help with a heavy manual door. The visitor should be able to request that help without finding staff phone numbers and coordinating each exchange themselves.

The backend needs to contact a registered responder, receive acceptance or refusal, answer questions, try another responder when necessary, and receive confirmation that help is ready. Photon provides the programmatic connection to staff members' existing Messages app. A different capable messaging or telephony provider could supply the same role; the necessary capability is automated two-way communication with people outside InView.

| Approach | What it provides |
|----------|------------------|
| Visitor shares a link from their own phone | Details and a response page; the visitor still has to initiate and coordinate contact |
| Access agent using Photon | The service contacts registered staff, manages replies and follow-ups, and connects the outcome to the active journey |

Apple's standard message composer lets an app prepare a message for a person to edit, send, or cancel. It does not supply this backend coordination loop. ([Apple message composer](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller))

## The experience

The visitor needs a step-free route to Floor 2. The building map identifies the North Lift as suitable, but it requires an attendant.

1. InView shows **"The North Lift requires an attendant. Arrange assistance?"** The visitor taps **Arrange assistance**.
2. The backend finds the building's registered staff contacts for that lift. Photon sends: **"An InView visitor requests assistance at the North Lift, Ground Floor, to reach Floor 2. Can you assist? Request A17."**
3. The first responder replies **"I'm helping someone else right now."** The agent records the refusal and contacts the next registered responder.
4. A responder replies **"Yes, I can be there in two minutes."** InView shows that someone has accepted and guides the visitor to an already reachable waiting area.
5. At the lift, the responder sends **"Ready at the North Lift. A17."** InView shows **"Your attendant is ready at the North Lift."** The assisted transition can proceed.
6. After the visitor reaches Floor 2, InView recovers floor identity and AR alignment before resuming normal guidance. The assisted part is marked complete when it has actually been traversed.

Staff participate through Messages without an InView account, staff app, or dashboard. The building operator supplies the roster, roles, and resources each person can assist with; scanning cannot discover staffing arrangements. The feature therefore targets participating campuses, venues, offices, and other staffed buildings.

## Hackathon MVP

- One mapped door or lift that requires assistance.
- One or two registered staff contacts, with a teammate acting as the attendant.
- A visitor action that starts an assistance request.
- Real outbound and inbound iMessages through Photon.
- Acceptance, stated ETA, and readiness reflected in the active AR journey.
- An unavailable result if nobody can help, plus cancellation of the request.
- A real physical outcome: the attendant helps the visitor through the door or operates the lift.

A public entrance with a heavy manual door is a practical physical demo if an attendant-operated lift is unavailable. Verify that the passage and its waiting area satisfy the demo visitor's selected route requirements.

## Architecture and team interfaces

Use **`spectrum-ts` with the hosted iMessage provider** in the backend. Photon documents hosted messaging and an incoming message stream; keep the conversation connected to the same journey state used by the native app. ([Photon Spectrum SDK](https://github.com/photon-hq/spectrum-ts), [getting started](https://photon.codes/docs/spectrum-ts/getting-started))

```text
Visitor requests assistance in InView
    → backend creates a journey-specific request
    → access agent selects a registered responder
    → Photon sends the request and receives staff replies
    → request state updates
    → native app updates guidance and the assisted transition
```

| Component | Responsibility |
|-----------|----------------|
| Scan and map creation | Identify the door/lift, its route properties, and a reachable waiting point |
| Building setup | Associate the resource with registered staff contacts and roles |
| Routing engine | Check eligibility, route to the waiting point, and validate proposed alternatives |
| Access agent | Interpret replies and manage the permitted assistance workflow |
| Photon | Deliver messages to staff and return their replies to the backend |
| iOS front end | Show request status, ETA, AR guidance, and floor-transition recovery |

### Proposed map and request data

Keep the snake_case style used in the navigation plan. Store assistance requirements separately from physical route suitability:

```text
North Lift:
    connector_id: north_lift
    step_free: true
    served_floors: [ground, floor_2]
    requires_attendant: true
    assistance_resource_id: north_lift_staff
    waiting_node_id: north_lift_waiting_area
```

Each assistance request belongs to one journey:

```text
request_id
journey_id
assistance_resource_id
waiting_node_id
assigned_responder_id
staff_conversation_id
status
stated_eta
```

Publish request-state changes to the native app with the request and journey IDs. The app uses the existing route engine and localization controller; the messaging agent does not place AR geometry or infer a new floor from a text reply.

### Request states

| State | Meaning and navigation behavior |
|-------|---------------------------------|
| **Requested** | Staff have been asked; assistance is not yet arranged |
| **Accepted** | A responder has committed; show their stated ETA and guide to the eligible waiting point |
| **Ready** | The assigned responder reports being at the correct resource and ready; the assisted step can proceed |
| **Completed** | The visitor has completed the assisted part of the journey |
| **Unavailable** | No responder can help; offer another eligible route or a clear unavailable result |
| **Cancelled** | The request has ended; subsequent replies must not advance the journey |

**Acceptance and readiness are different.** "I'll be there in two minutes" cannot be treated as "I'm ready at the lift." Readiness applies to the particular request and responder; it must not permanently mark the resource available for everyone. If a reply could refer to more than one request or location, ask for clarification before advancing it.

Assistance preserves the visitor's route requirements. It cannot make a staircase step-free or make a narrow doorway wide enough. A proposed alternative such as **"Use the south lift; I'm stationed there"** must pass the normal route checks before the destination changes. During elevator travel, resume positional AR guidance only after confirming the landing and recovering alignment.

## The AI's role

Keep the agent's actions narrow:

- Find an appropriate registered responder.
- Send the assistance request initiated by the visitor.
- Answer a question about the mapped location or destination floor.
- Record acceptance, refusal, a stated ETA, or readiness.
- Ask the route engine to evaluate a suggested alternative.
- Update the request and active journey.

The agent can interpret **"I'm off duty," "Which entrance?", "I can help in a minute,"** or **"I'm here now."** Resolve location names against building data and clarify ambiguous replies. The route engine determines reachability; the model phrases the result and manages the conversation.

The visitor starts the request. Contact only the staff registered for that resource and share the location, requested action, destination floor, and request reference needed to arrange help. A diagnosis or disability label is unnecessary for the example request.

## Voice calling stretch

A stronger extension serves a visitor who wants to communicate by text when assistance is available only through a voice reception line. The visitor types **"I'm at the west entrance. Can you ask reception to help me through the door?"** The agent calls reception, identifies itself as an automated assistant acting at the visitor's request, arranges help, and returns the outcome as text. This could support deaf visitors or people with speech disabilities who prefer text communication. A landline cannot use a shared meeting link.

Photon's Stable documentation currently supports inbound and outbound calls on iMessage lines through a **separate SIP-connected application**. Voice webhooks and `spectrum-ts` call control remain on the roadmap; live calls do not arrive through the normal messaging stream. ([Photon voice documentation](https://photon.codes/docs/spectrum-ts/providers/voice))

ElevenLabs supports inbound and outbound SIP calling and is a candidate for the voice agent. The Photon–ElevenLabs combination remains **untested for InView**. Prove a working call early before adding voice to the hackathon scope; the two-way iMessage workflow is the first implementation. ([ElevenLabs SIP integration](https://elevenlabs.io/docs/eleven-agents/phone-numbers/sip-trunking))

## Build and demo order

1. Agree on the resource, staff roster, waiting node, request states, and interface to the journey controller.
2. Prove real outbound and inbound Photon messaging with a registered demo responder.
3. Connect visitor request creation, staff acceptance/refusal, fallback to another responder, and readiness.
4. Route to the waiting point after acceptance, hold the assisted step until readiness, then complete the physical passage and resume navigation.
5. Check cancellation, unanswered requests, ambiguous replies, and unavailable assistance. Define a bounded response window and avoid repeatedly contacting staff indefinitely.
6. Add conversational interpretation and concise status messages. Consider voice only after the iMessage journey works end to end.

Show two phones: the visitor sees the assistance prompt; the attendant receives and replies to an iMessage. Demonstrate acceptance first, then the attendant physically arriving and confirming readiness. End with the visitor continuing through the space. A sent message alone is not a completed assistance request.

## Earlier ideas and open questions

**Meet me:** the earlier proposal resolved a host's room, found a meeting point both people could reach, and turned their agreement into an AR destination. The discussion concluded that a visitor-shared link could deliver almost the same experience. Keep it as a possible shared-link feature; it is not the main justification for Photon.

**Staff availability reports:** staff could text **"Elevator A is out of service"** to update a connector and reroute affected journeys. This is a separate, smaller possible integration. It requires verified staff reporting; the access-agent MVP uses per-request assistance state rather than building-wide availability edits.

Before implementation, confirm:

1. Who owns the Photon/backend workflow, and who owns its iOS journey integration?
2. Which real door or lift, waiting point, and registered responders will the demo use?
3. What response window, fallback order, cancellation behavior, and completion signal should the request use?
4. What are the onsite Photon sponsor requirements for the SDK, demo, and submission? The planning conversation did not establish the exact judging prompt.

Provider capability notes were checked against Photon Stable documentation on October 10, 2026. This is an implementation plan, not a claim that the integration has been built or tested.
