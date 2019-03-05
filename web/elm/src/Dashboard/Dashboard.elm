module Dashboard.Dashboard exposing
    ( Model
    , handleCallback
    , handleDelivery
    , init
    , subscriptions
    , update
    , view
    )

import Callback exposing (Callback(..))
import Concourse
import Concourse.Cli as Cli
import Concourse.PipelineStatus as PipelineStatus exposing (PipelineStatus(..))
import Concourse.User
import Dashboard.APIData as APIData
import Dashboard.Details as Details
import Dashboard.Footer as Footer
import Dashboard.Group as Group
import Dashboard.Models as Models
import Dashboard.Msgs as Msgs exposing (Msg(..))
import Dashboard.Styles as Styles
import Dashboard.SubState as SubState
import Dashboard.Text as Text
import Effects exposing (Effect(..))
import Html.Styled as Html exposing (Html)
import Html.Styled.Attributes
    exposing
        ( attribute
        , class
        , classList
        , css
        , draggable
        , href
        , id
        , src
        , style
        )
import Html.Styled.Events exposing (onMouseEnter, onMouseLeave)
import Http
import Monocle.Common exposing ((<|>), (=>))
import Monocle.Lens
import Monocle.Optional
import MonocleHelpers exposing (..)
import Regex exposing (HowMany(All), regex, replace)
import RemoteData
import Routes
import ScreenSize
import Simple.Fuzzy exposing (filter, match, root)
import Subscription exposing (Delivery(..), Interval(..), Subscription(..))
import Task
import TopBar.Model
import TopBar.Msgs
import TopBar.Styles
import TopBar.TopBar as TopBar
import UserState exposing (UserState)


type alias Flags =
    { turbulencePath : String
    , searchType : Routes.SearchType
    , pipelineRunningKeyframes : String
    }


type DashboardError
    = Turbulence String


type alias Model =
    Footer.Model
        (TopBar.Model.Model
            { state : RemoteData.RemoteData DashboardError SubState.SubState
            , turbulencePath : String
            , hoveredPipeline : Maybe Models.Pipeline
            , pipelineRunningKeyframes : String
            , hoveredTopCliIcon : Maybe Cli.Cli
            , userState : UserState.UserState
            }
        )


substateOptional : Monocle.Optional.Optional Model SubState.SubState
substateOptional =
    Monocle.Optional.Optional (.state >> RemoteData.toMaybe) (\s m -> { m | state = RemoteData.Success s })


init : Flags -> ( Model, List Effect )
init flags =
    let
        ( topBar, topBarEffects ) =
            TopBar.init { route = Routes.Dashboard { searchType = flags.searchType } }
    in
    ( { state = RemoteData.NotAsked
      , turbulencePath = flags.turbulencePath
      , hoveredPipeline = Nothing
      , pipelineRunningKeyframes = flags.pipelineRunningKeyframes
      , groups = []
      , hoveredCliIcon = Nothing
      , hoveredTopCliIcon = Nothing
      , version = ""
      , userState = UserState.UserStateUnknown
      , hideFooter = False
      , hideFooterCounter = 0
      , showHelp = False
      , isUserMenuExpanded = topBar.isUserMenuExpanded
      , isPinMenuExpanded = topBar.isPinMenuExpanded
      , route = topBar.route
      , query = topBar.query
      , dropdown = topBar.dropdown
      , screenSize = topBar.screenSize
      , shiftDown = topBar.shiftDown
      }
    , [ FetchData
      , PinTeamNames Group.stickyHeaderConfig
      , SetTitle <| "Dashboard" ++ " - "
      , GetScreenSize
      ]
        ++ topBarEffects
    )


isHighDensity : { a | route : Routes.Route } -> Bool
isHighDensity { route } =
    case route of
        Routes.Dashboard { searchType } ->
            searchType == Routes.HighDensity

        _ ->
            False


handleCallback : Callback -> ( Model, List Effect ) -> ( Model, List Effect )
handleCallback msg =
    TopBar.handleCallback msg >> handleCallbackWithoutTopBar msg


handleCallbackWithoutTopBar : Callback -> ( Model, List Effect ) -> ( Model, List Effect )
handleCallbackWithoutTopBar msg ( model, effects ) =
    case msg of
        APIDataFetched (Err _) ->
            ( { model | state = RemoteData.Failure (Turbulence model.turbulencePath) }, effects )

        APIDataFetched (Ok ( now, apiData )) ->
            let
                groups =
                    Group.groups apiData

                noPipelines =
                    List.isEmpty <| List.concatMap .pipelines groups

                newModel =
                    case model.state of
                        RemoteData.Success substate ->
                            { model
                                | state =
                                    RemoteData.Success (SubState.tick now substate)
                            }

                        _ ->
                            { model
                                | state =
                                    RemoteData.Success
                                        { now = now
                                        , dragState = Group.NotDragging
                                        , dropState = Group.NotDropping
                                        }
                            }

                userState =
                    case apiData.user of
                        Just u ->
                            UserState.UserStateLoggedIn u

                        Nothing ->
                            UserState.UserStateLoggedOut
            in
            if isHighDensity model && noPipelines then
                ( { newModel
                    | groups = groups
                    , route = Routes.dashboardRoute False
                    , version = apiData.version
                    , userState = userState
                  }
                , effects
                    ++ [ ModifyUrl <|
                            Routes.toString <|
                                Routes.dashboardRoute False
                       ]
                )

            else
                ( { newModel
                    | groups = groups
                    , version = apiData.version
                    , userState = userState
                  }
                , effects
                )

        LoggedOut (Ok ()) ->
            ( { model | userState = UserState.UserStateLoggedOut }
            , effects
                ++ [ NavigateTo <|
                        Routes.toString <|
                            Routes.dashboardRoute <|
                                isHighDensity model
                   , FetchData
                   ]
            )

        LoggedOut (Err err) ->
            flip always (Debug.log "failed to log out" err) <|
                ( model, effects )

        ScreenResized size ->
            let
                newSize =
                    ScreenSize.fromWindowSize size
            in
            ( { model | screenSize = newSize }, effects )

        _ ->
            ( model, effects )


handleDelivery : Delivery -> ( Model, List Effect ) -> ( Model, List Effect )
handleDelivery delivery =
    TopBar.handleDelivery delivery
        >> Footer.handleDelivery delivery
        >> handleDeliveryBody delivery


handleDeliveryBody : Delivery -> ( Model, List Effect ) -> ( Model, List Effect )
handleDeliveryBody delivery ( model, effects ) =
    case delivery of
        ClockTicked OneSecond time ->
            ( { model | state = RemoteData.map (SubState.tick time) model.state }
            , effects
            )

        ClockTicked FiveSeconds _ ->
            ( model, effects ++ [ FetchData ] )

        _ ->
            ( model, effects )


update : Msg -> ( Model, List Effect ) -> ( Model, List Effect )
update msg ( model, effects ) =
    case msg of
        TogglePipelinePaused pipeline ->
            ( model, effects ++ [ SendTogglePipelineRequest pipeline ] )

        DragStart teamName index ->
            let
                newModel =
                    { model | state = RemoteData.map (\s -> { s | dragState = Group.Dragging teamName index }) model.state }
            in
            ( newModel, effects )

        DragOver teamName index ->
            let
                newModel =
                    { model | state = RemoteData.map (\s -> { s | dropState = Group.Dropping index }) model.state }
            in
            ( newModel, effects )

        TooltipHd pipelineName teamName ->
            ( model, effects ++ [ ShowTooltipHd ( pipelineName, teamName ) ] )

        Tooltip pipelineName teamName ->
            ( model, effects ++ [ ShowTooltip ( pipelineName, teamName ) ] )

        DragEnd ->
            let
                updatePipelines :
                    ( Group.PipelineIndex, Group.PipelineIndex )
                    -> Group.Group
                    -> ( Group.Group, List Effect )
                updatePipelines ( dragIndex, dropIndex ) group =
                    let
                        newGroup =
                            Group.shiftPipelines dragIndex dropIndex group
                    in
                    ( newGroup
                    , [ SendOrderPipelinesRequest newGroup.teamName newGroup.pipelines ]
                    )

                dragDropOptional : Monocle.Optional.Optional Model ( Group.DragState, Group.DropState )
                dragDropOptional =
                    substateOptional
                        =|> Monocle.Lens.tuple
                                Details.dragStateLens
                                Details.dropStateLens

                dragDropIndexOptional : Monocle.Optional.Optional Model ( Group.PipelineIndex, Group.PipelineIndex )
                dragDropIndexOptional =
                    dragDropOptional
                        => Monocle.Optional.zip
                            Group.dragIndexOptional
                            Group.dropIndexOptional

                groupsLens : Monocle.Lens.Lens Model (List Group.Group)
                groupsLens =
                    Monocle.Lens.Lens .groups (\b a -> { a | groups = b })

                groupOptional : Monocle.Optional.Optional Model Group.Group
                groupOptional =
                    (substateOptional
                        =|> Details.dragStateLens
                        => Group.teamNameOptional
                    )
                        >>= (\teamName ->
                                groupsLens
                                    <|= Group.findGroupOptional teamName
                            )

                bigOptional : Monocle.Optional.Optional Model ( ( Group.PipelineIndex, Group.PipelineIndex ), Group.Group )
                bigOptional =
                    Monocle.Optional.tuple
                        dragDropIndexOptional
                        groupOptional

                ( newModel, unAccumulatedEffects ) =
                    model
                        |> modifyWithEffect bigOptional
                            (\( t, g ) ->
                                let
                                    ( newG, msg ) =
                                        updatePipelines t g
                                in
                                ( ( t, newG ), msg )
                            )
                        |> Tuple.mapFirst (dragDropOptional.set ( Group.NotDragging, Group.NotDropping ))
            in
            ( newModel, effects ++ unAccumulatedEffects )

        PipelineButtonHover state ->
            ( { model | hoveredPipeline = state }, effects )

        CliHover state ->
            ( { model | hoveredCliIcon = state }, effects )

        TopCliHover state ->
            ( { model | hoveredTopCliIcon = state }, effects )

        FromTopBar m ->
            let
                ( newModel, topBarEffects ) =
                    TopBar.update m ( model, effects )
            in
            case m of
                TopBar.Msgs.LogOut ->
                    ( { newModel | state = RemoteData.NotAsked }, topBarEffects )

                _ ->
                    ( newModel, topBarEffects )


subscriptions : Model -> List Subscription
subscriptions model =
    [ OnClockTick OneSecond
    , OnClockTick FiveSeconds
    , OnMouse
    , OnKeyDown
    , OnKeyUp
    , OnWindowResize
    ]


view : UserState -> Model -> Html Msg
view userState model =
    Html.div []
        [ Html.div
            [ style TopBar.Styles.pageIncludingTopBar, id "page-including-top-bar" ]
            [ Html.map FromTopBar (TopBar.view userState TopBar.Model.None model)
            , Html.div [ id "page-below-top-bar", style TopBar.Styles.pageBelowTopBar ]
                [ dashboardView model
                ]
            ]
        ]


dashboardView : Model -> Html Msg
dashboardView model =
    let
        mainContent =
            case model.state of
                RemoteData.NotAsked ->
                    [ Html.text "" ]

                RemoteData.Loading ->
                    [ Html.text "" ]

                RemoteData.Failure (Turbulence path) ->
                    [ turbulenceView path ]

                RemoteData.Success substate ->
                    [ Html.div
                        [ class "dashboard-content" ]
                      <|
                        welcomeCard model
                            ++ pipelinesView
                                { groups = model.groups
                                , substate = substate
                                , query = model.query
                                , hoveredPipeline = model.hoveredPipeline
                                , pipelineRunningKeyframes =
                                    model.pipelineRunningKeyframes
                                , userState = model.userState
                                , highDensity = isHighDensity model
                                }
                    ]
                        ++ (List.map Html.fromUnstyled <| Footer.view model)
    in
    Html.div
        [ classList
            [ ( .pageBodyClass Group.stickyHeaderConfig, True )
            , ( "dashboard-hd", isHighDensity model )
            ]
        ]
        mainContent


welcomeCard :
    { a
        | hoveredTopCliIcon : Maybe Cli.Cli
        , groups : List Group.Group
        , userState : UserState.UserState
    }
    -> List (Html Msg)
welcomeCard { hoveredTopCliIcon, groups, userState } =
    let
        noPipelines =
            List.isEmpty (groups |> List.concatMap .pipelines)

        cliIcon : Maybe Cli.Cli -> Cli.Cli -> Html Msg
        cliIcon hoveredTopCliIcon cli =
            Html.a
                [ href (Cli.downloadUrl cli)
                , attribute "aria-label" <| Cli.label cli
                , style <|
                    Styles.topCliIcon
                        { hovered = hoveredTopCliIcon == Just cli
                        , cli = cli
                        }
                , id <| "top-cli-" ++ Cli.id cli
                , onMouseEnter <| TopCliHover <| Just cli
                , onMouseLeave <| TopCliHover Nothing
                ]
                []
    in
    if noPipelines then
        [ Html.div
            [ id "welcome-card"
            , style Styles.welcomeCard
            ]
            [ Html.div
                [ style Styles.welcomeCardTitle ]
                [ Html.text Text.welcome ]
            , Html.div
                [ style Styles.welcomeCardBody ]
              <|
                [ Html.div
                    [ style
                        [ ( "display", "flex" )
                        , ( "align-items", "center" )
                        ]
                    ]
                  <|
                    [ Html.div
                        [ style [ ( "margin-right", "10px" ) ] ]
                        [ Html.text Text.cliInstructions ]
                    ]
                        ++ List.map (cliIcon hoveredTopCliIcon) Cli.clis
                , Html.div
                    []
                    [ Html.text Text.setPipelineInstructions ]
                ]
                    ++ loginInstruction userState
            , Html.pre
                [ style Styles.asciiArt ]
                [ Html.text Text.asciiArt ]
            ]
        ]

    else
        []


loginInstruction : UserState.UserState -> List (Html Msg)
loginInstruction userState =
    case userState of
        UserState.UserStateLoggedIn _ ->
            []

        _ ->
            [ Html.div
                [ id "login-instruction"
                , style [ ( "line-height", "42px" ) ]
                ]
                [ Html.text "login "
                , Html.a
                    [ href "/login"
                    , style [ ( "text-decoration", "underline" ) ]
                    ]
                    [ Html.text "here" ]
                ]
            ]


noResultsView : String -> Html Msg
noResultsView query =
    let
        boldedQuery =
            Html.span [ class "monospace-bold" ] [ Html.text query ]
    in
    Html.div
        [ class "no-results"
        , style Styles.noResults
        ]
        [ Html.text "No results for "
        , boldedQuery
        , Html.text " matched your search."
        ]


turbulenceView : String -> Html Msg
turbulenceView path =
    Html.div
        [ class "error-message" ]
        [ Html.div [ class "message" ]
            [ Html.img [ src path, class "seatbelt" ] []
            , Html.p [] [ Html.text "experiencing turbulence" ]
            , Html.p [ class "explanation" ] []
            ]
        ]


pipelinesView :
    { groups : List Group.Group
    , substate : SubState.SubState
    , hoveredPipeline : Maybe Models.Pipeline
    , pipelineRunningKeyframes : String
    , query : String
    , userState : UserState.UserState
    , highDensity : Bool
    }
    -> List (Html Msg)
pipelinesView { groups, substate, hoveredPipeline, pipelineRunningKeyframes, query, userState, highDensity } =
    let
        filteredGroups =
            groups |> filter query |> List.sortWith Group.ordering

        groupsToDisplay =
            if List.all (String.startsWith "team:") (filterTerms query) then
                filteredGroups

            else
                filteredGroups |> List.filter (.pipelines >> List.isEmpty >> not)

        groupViews =
            if highDensity then
                groupsToDisplay
                    |> List.map (Group.hdView pipelineRunningKeyframes)

            else
                groupsToDisplay
                    |> List.map
                        (Group.view
                            { dragState = substate.dragState
                            , dropState = substate.dropState
                            , now = substate.now
                            , hoveredPipeline = hoveredPipeline
                            , pipelineRunningKeyframes = pipelineRunningKeyframes
                            }
                        )
    in
    if List.isEmpty groupViews && (not <| String.isEmpty query) then
        [ noResultsView (toString query) ]

    else
        List.map Html.fromUnstyled groupViews


remoteUser : APIData.APIData -> Task.Task Http.Error ( APIData.APIData, Maybe Concourse.User )
remoteUser d =
    Concourse.User.fetchUser
        |> Task.map ((,) d << Just)
        |> Task.onError (always <| Task.succeed <| ( d, Nothing ))


filterTerms : String -> List String
filterTerms =
    replace All (regex "team:\\s*") (\_ -> "team:")
        >> replace All (regex "status:\\s*") (\_ -> "status:")
        >> String.words
        >> List.filter (not << String.isEmpty)


filter : String -> List Group.Group -> List Group.Group
filter =
    filterTerms >> flip (List.foldl filterGroupsByTerm)


filterPipelinesByTerm : String -> Group.Group -> Group.Group
filterPipelinesByTerm term ({ pipelines } as group) =
    let
        searchStatus =
            String.startsWith "status:" term

        statusSearchTerm =
            if searchStatus then
                String.dropLeft 7 term

            else
                term

        filterByStatus =
            fuzzySearch (.status >> PipelineStatus.show) statusSearchTerm pipelines
    in
    { group
        | pipelines =
            if searchStatus then
                filterByStatus

            else
                fuzzySearch .name term pipelines
    }


filterGroupsByTerm : String -> List Group.Group -> List Group.Group
filterGroupsByTerm term groups =
    let
        searchTeams =
            String.startsWith "team:" term

        teamSearchTerm =
            if searchTeams then
                String.dropLeft 5 term

            else
                term
    in
    if searchTeams then
        fuzzySearch .teamName teamSearchTerm groups

    else
        groups |> List.map (filterPipelinesByTerm term)


fuzzySearch : (a -> String) -> String -> List a -> List a
fuzzySearch map needle records =
    let
        negateSearch =
            String.startsWith "-" needle
    in
    if negateSearch then
        List.filter (not << Simple.Fuzzy.match needle << map) records

    else
        List.filter (Simple.Fuzzy.match needle << map) records
