{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Reporting.Error.Type
  ( Error(..)
  , Mismatch(..), Hint(..)
  , Reason(..), SpecificThing(..)
  , Pattern(..)
  , toReport
  , flipReason
  )
  where

import Control.Arrow (first, second)
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text
import Data.Text (Text)

import qualified AST.Helpers as Help
import qualified AST.Type as Type
import qualified AST.Variable as Var
import qualified Reporting.Region as Region
import qualified Reporting.Render.Type as RenderType
import qualified Reporting.Report as Report
import qualified Reporting.Helpers as Help
import Reporting.Helpers
  ( Doc, (<>), (<+>), capitalize, dullyellow, functionName
  , i2t, indent, ordinalize, reflowParagraph, stack, text, toHint, vcat
  )



-- ERRORS


data Error
    = Mismatch Mismatch
    | BadMain Type.Canonical
    | BadFlags Type.Canonical (Maybe Text)
    | InfiniteType (Either Hint Text) Type.Canonical


data Mismatch = MismatchInfo
    { _hint :: Hint
    , _leftType :: Type.Canonical
    , _rightType :: Type.Canonical
    , _reason :: Maybe Reason
    }


data Reason
    = BadFields [(Text, Maybe Reason)]
    | MessyFields [Text] [Text] [Text]
    | IntFloat
    | TooLongComparableTuple Int
    | MissingArgs Int
    | RigidClash Text Text
    | NotPartOfSuper Type.Super
    | RigidVarTooGeneric Text SpecificThing
    | RigidSuperTooGeneric Type.Super Text SpecificThing


data SpecificThing
  = SpecificSuper Type.Super
  | SpecificType Var.Canonical
  | SpecificFunction
  | SpecificRecord


data Hint
    = CaseBranch Int Region.Region
    | Case
    | IfCondition
    | IfBranches
    | MultiIfBranch Int Region.Region
    | If
    | List
    | ListElement Int Region.Region
    | BinopLeft Var.Canonical Region.Region
    | BinopRight Var.Canonical Region.Region
    | Binop Var.Canonical
    | Function (Maybe Var.Canonical)
    | UnexpectedArg (Maybe Var.Canonical) Int Int Region.Region
    | FunctionArity (Maybe Var.Canonical) Int Int Region.Region
    | ReturnType Text Int Int Region.Region
    | Instance Text
    | Literal Text
    | Pattern Pattern
    | Shader
    | Lambda
    | Access (Maybe Text) Text
    | Record
    -- effect manager problems
    | Manager Text
    | State Text
    | SelfMsg


data Pattern
    = PVar Text
    | PAlias Text
    | PCtor Var.Canonical
    | PRecord



-- TO REPORT


toReport :: RenderType.Localizer -> Error -> Report.Report
toReport localizer err =
  case err of
    Mismatch info ->
        mismatchToReport localizer info

    InfiniteType context overallType ->
        infiniteTypeToReport localizer context overallType

    BadMain tipe ->
        Report.report
          "BAD MAIN TYPE"
          Nothing
          "The `main` value has an unsupported type."
          ( stack
              [ reflowParagraph $
                "I need Html, Svg, or a Program so I have something to render on\
                \ screen, but you gave me:"
              , indent 4 (RenderType.toDoc localizer tipe)
              ]
          )

    BadFlags tipe maybeMessage ->
      let
        context =
          maybe "" (" the following " <> ) maybeMessage
      in
        Report.report
          "BAD FLAGS"
          Nothing
          ("Your `main` is demanding an unsupported type as a flag."
          )
          ( stack
              [ text ("The specific unsupported type is" <> context <> ":")
              , indent 4 (RenderType.toDoc localizer tipe)
              , text "The types of values that can flow through in and out of Elm include:"
              , indent 4 $ reflowParagraph $
                  "Ints, Floats, Bools, Strings, Maybes, Lists, Arrays,\
                  \ Tuples, Json.Values, and concrete records."
              ]
          )



-- TYPE MISMATCHES


mismatchToReport :: RenderType.Localizer -> Mismatch -> Report.Report
mismatchToReport localizer (MismatchInfo hint leftType rightType maybeReason) =
  let
    report =
      Report.report "TYPE MISMATCH"

    typicalHints =
      Maybe.maybeToList (reasonToString =<< maybeReason)

    cmpHint leftWords rightWords extraHints =
      comparisonHint localizer leftType rightType leftWords rightWords
        (typicalHints <> map toHint extraHints)
  in
  case hint of
    CaseBranch branchNumber region ->
        report
          (Just region)
          ( "The " <> ordinalPair branchNumber
            <> " branches of this `case` produce different types of values."
          )
          ( cmpHint
              ("The " <> ordinalize (branchNumber - 1) <> " branch has this type:")
              ("But the " <> ordinalize branchNumber <> " is:")
              [ "All branches in a `case` must have the same type. So no matter\
                \ which one we take, we always get back the same type of value."
              ]
          )

    Case ->
        report
          Nothing
          ( "All the branches of this case-expression are consistent, but the overall\n"
            <> "type does not match how it is used elsewhere."
          )
          ( cmpHint
              "The `case` evaluates to something of type:"
              "Which is fine, but the surrounding context wants it to be:"
              []
          )

    IfCondition ->
        report
          Nothing
          "This condition does not evaluate to a boolean value, True or False."
          ( cmpHint
              "You have given me a condition with this type:"
              "But I need it to be:"
              [ "Elm does not have \"truthiness\" such that ints and strings and lists\
                \ are automatically converted to booleans. Do that conversion explicitly."
              ]
          )

    IfBranches ->
        report
          Nothing
          "The branches of this `if` produce different types of values."
          ( cmpHint
              "The `then` branch has type:"
              "But the `else` branch is:"
              [ "These need to match so that no matter which branch we take, we\
                \ always get back the same type of value."
              ]
          )

    MultiIfBranch branchNumber region ->
        report
          (Just region)
          ( "The " <> ordinalPair branchNumber
            <> " branches of this `if` produce different types of values."
          )
          ( cmpHint
              ("The " <> ordinalize (branchNumber - 1) <> " branch has this type:")
              ("But the "<> ordinalize branchNumber <> " is:")
              [ "All the branches of an `if` need to match so that no matter which\
                \ one we take, we get back the same type of value overall."
              ]
          )

    If ->
        report
          Nothing
          "All the branches of this `if` are consistent, but the overall\
          \ type does not match how it is used elsewhere."
          ( cmpHint
              "The `if` evaluates to something of type:"
              "Which is fine, but the surrounding context wants it to be:"
              []
          )

    ListElement elementNumber region ->
        report
          (Just region)
          ("The " <> ordinalPair elementNumber <> " entries in this list are different types of values.")
          ( cmpHint
              ("The " <> ordinalize (elementNumber - 1) <> " entry has this type:")
              ("But the "<> ordinalize elementNumber <> " is:")
              [ "Every entry in a list needs to be the same type of value.\
                \ This way you never run into unexpected values partway through.\
                \ To mix different types in a single list, create a \"union type\" as\
                \ described in: <http://guide.elm-lang.org/types/union_types.html>"
              ]
          )

    List ->
        report
          Nothing
          ( "All the elements in this list are the same type, but the overall\
            \ type does not match how it is used elsewhere."
          )
          ( cmpHint
              "The list has type:"
              "Which is fine, but the surrounding context wants it to be:"
              []
          )

    BinopLeft op region ->
        report
          (Just region)
          ("The left argument of " <> varName op <> " is causing a type mismatch.")
          ( cmpHint
              (varName op <> " is expecting the left argument to be a:")
              "But the left argument is:"
              (binopHint op leftType rightType)
          )

    BinopRight op region ->
        report
          (Just region)
          ("The right side of " <> varName op <> " is causing a type mismatch.")
          ( cmpHint
              (varName op <> " is expecting the right side to be a:")
              "But the right side is:"
              ( binopHint op leftType rightType
                ++
                [ "With operators like " <> varName op <> " I always check the left\
                  \ side first. If it seems fine, I assume it is correct and check the right\
                  \ side. So the problem may be in how the left and right arguments interact."
                ]
              )
          )

    Binop op ->
        report
          Nothing
          ( "The two arguments to " <> varName op <>
            " are fine, but the overall type of this expression\
            \ does not match how it is used elsewhere."
          )
          ( cmpHint
              "The result of this binary operation is:"
              "Which is fine, but the surrounding context wants it to be:"
              []
          )

    Function maybeName ->
        report
          Nothing
          ( "The return type of " <> maybeFuncName maybeName <> " is being used in unexpected ways."
          )
          ( cmpHint
              "The function results in this type of value:"
              "Which is fine, but the surrounding context wants it to be:"
              []
          )

    UnexpectedArg maybeName 1 1 region ->
        report
          (Just region)
          ("The argument to " <> maybeFuncName maybeName <> " is causing a mismatch.")
          ( cmpHint
              (capitalize (maybeFuncName maybeName) <> " is expecting the argument to be:")
              "But it is:"
              (functionHint maybeName)
          )

    UnexpectedArg maybeName index _totalArgs region ->
        report
          (Just region)
          ( "The " <> ordinalize index <> " argument to " <> maybeFuncName maybeName
            <> " is causing a mismatch."
          )
          ( cmpHint
              ( capitalize (maybeFuncName maybeName) <> " is expecting the "
                <> ordinalize index <> " argument to be:"
              )
              "But it is:"
              ( functionHint maybeName
                ++
                if index == 1 then
                  []
                else
                  [ "I always figure out the type of arguments from left to right. If an argument\
                    \ is acceptable when I check it, I assume it is \"correct\" in subsequent checks.\
                    \ So the problem may actually be in how previous arguments interact with the "
                    <> ordinalize index <> "."
                  ]
              )
          )

    FunctionArity maybeName 0 actual region ->
        let
          args =
            if actual == 1 then "an argument" else i2t actual <> " arguments"

          preHint =
            case maybeName of
              Nothing ->
                  "You are giving " <> args <> " to something that is not a function!"

              Just name ->
                  varName name <> " is not a function, but you are giving it " <> args <> "!"
        in
          report
            (Just region)
            preHint
            (text "Maybe you forgot some parentheses? Or a comma?")

    FunctionArity maybeName expected actual region ->
      report
          (Just region)
          ( capitalize (maybeFuncName maybeName) <> " is expecting "
            <> Help.args expected <> ", but was given " <> i2t actual <> "."
          )
          (text "Maybe you forgot some parentheses? Or a comma?")

    ReturnType name typeArity argArity region ->
      if typeArity == 0 || argArity == 0 then
        report
          (Just region)
          ("The definition of " <> functionName name <> " does not match its type annotation.")
          ( cmpHint
              ( "The type annotation for " <> functionName name <> " says it is a:"
              )
              "But the definition (shown above) is a:"
              (arityHint typeArity argArity)
          )

      else
        report
          (Just region)
          ("The definition of " <> functionName name <> " does not match its type annotation.")
          ( cmpHint
              ( "The type annotation for " <> functionName name <> " says it always returns:"
              )
              "But the returned value (shown above) is a:"
              (arityHint typeArity argArity)
          )

    Instance var ->
      let
        name =
          functionName var
      in
        report
          Nothing
          (name <> " is being used in an unexpected way.")
          ( cmpHint
              ("Based on its definition, " <> name <> " has this type:")
              "But you are trying to use it as:"
              []
          )

    Literal name ->
        report
          Nothing
          ( "This " <> name <> " value is being used as if it is some other type of value."
          )
          ( cmpHint
              ("The " <> name <> " definitely has this type:")
              ("But it is being used as:")
              []
          )

    Pattern patErr ->
        let
          thing =
            case patErr of
              PVar name ->
                "variable `" <> name <> "`"

              PAlias name ->
                "alias `" <> name <> "`"

              PRecord ->
                "this record"

              PCtor (Var.Canonical Var.BuiltIn name) | Help.isTuple name ->
                "this tuple"

              PCtor name ->
                "tag `" <> Var.toText name <> "`"
        in
          report
            Nothing
            ( capitalize thing <> " is causing problems in this pattern match."
            )
            ( cmpHint
                "The pattern matches things of type:"
                "But the values it will actually be trying to match are:"
                []
            )

    Shader ->
        report
          Nothing
          "There is some problem with this GLSL shader."
          ( cmpHint
              "The shader block has this type:"
              "Which is fine, but the surrounding context wants it to be:"
              []
          )

    Lambda ->
        report
          Nothing
          "This function is being used in an unexpected way."
          ( cmpHint
              "The function has type:"
              "But you are trying to use it as:"
              []
          )

    Access (Just body) field ->
      let
        header = "`" <> body <> "` does not have a field named `" <> field <> "`."
      in
        report Nothing header $ stack $
          [ reflowParagraph $ "The type of `" <> body <> "` is:"
          , indent 4 $ dullyellow $ RenderType.toDoc localizer leftType
          , reflowParagraph $ "Which does not contain a field named `" <> field <> "`."
          ]
          ++ typicalHints

    Access Nothing field ->
      let
        header = "Cannot access a field named `" <> field <> "`."
      in
        report Nothing header $ stack $
          [ reflowParagraph $ "You are trying to get `" <> field <> "` from a value with this type:"
          , indent 4 $ dullyellow $ RenderType.toDoc localizer leftType
          , reflowParagraph $ "It is not in there!"
          ]
          ++ typicalHints

    Record ->
        report
          Nothing
          "This record is being used in an unexpected way."
          ( cmpHint
              "The record has type:"
              "But you are trying to use it as:"
              []
          )

    Manager name ->
        report
          Nothing
          ("The `" <> name <> "` in your effect manager has a weird type.")
          ( cmpHint
              ("Your `" <> name <> "` function has this type:")
              "But it needs to have a type like this:"
              [ "You can read more about setting up effect managers properly here:\
                \ <http://guide.elm-lang.org/effect_managers/>"
              ]
          )

    State name ->
        report
          Nothing
          ( "Your effect manager creates a certain type of state with `init`, but your `"
            <> name <> "` function expects a different kind of state."
          )
          ( cmpHint
              "The state created by `init` has this type:"
              ("But `" <> name <> "` expects state of this type:")
              [ "Make the two state types match and you should be all set! More info here:\
                \ <http://guide.elm-lang.org/effect_managers/>"
              ]
          )

    SelfMsg ->
        report
          Nothing
          "Effect managers can send messages to themselves, but `onEffects` and `onSelfMsg` are defined for different types of self messages."
          ( cmpHint
              "The `onEffects` function can send this type of message:"
              "But the `onSelfMsg` function receives this type:"
              [ "Make the two message types match and you should be all set! More info here:\
                \ <http://guide.elm-lang.org/effect_managers/>"
              ]
          )




comparisonHint
    :: RenderType.Localizer
    -> Type.Canonical
    -> Type.Canonical
    -> Text
    -> Text
    -> [Doc]
    -> Doc
comparisonHint localizer leftType rightType leftWords rightWords finalHints =
  let
    (leftDoc, rightDoc) =
      RenderType.diffToDocs localizer leftType rightType
  in
    stack $
      [ reflowParagraph leftWords
      , indent 4 leftDoc
      , reflowParagraph rightWords
      , indent 4 rightDoc
      ]
      ++
      finalHints



-- BINOP HINTS


binopHint :: Var.Canonical -> Type.Canonical -> Type.Canonical -> [Text]
binopHint op leftType rightType =
  let
    leftString =
      show (RenderType.toDoc Map.empty leftType)

    rightString =
      show (RenderType.toDoc Map.empty rightType)
  in
    if Var.is "Basics" "+" op && elem "String" [leftString, rightString] then
        [ "To append strings in Elm, you need to use the (++) operator, not (+).\
          \ <http://package.elm-lang.org/packages/elm-lang/core/latest/Basics#++>"
        ]

    else if Var.is "Basics" "/" op && elem "Int" [leftString, rightString] then
        [ "The (/) operator is specifically for floating point division, and (//) is\
          \ for integer division. You may need to do some conversions between ints and\
          \ floats to get both arguments matching the division operator you want."
        ]

    else
        []



-- FUNCTION HINTS


functionHint :: Maybe Var.Canonical -> [Text]
functionHint maybeName =
  case maybeName of
    Nothing ->
      []

    Just name ->
      if Var.inHtml "Html" "program" == name then
        [ "Does your program have flags? Maybe you want `programWithFlags` instead."
        ]

      else
        []



-- ARITY HINTS


arityHint :: Int -> Int -> [Text]
arityHint typeArity argArity =
  if typeArity == argArity then
    []

  else
    [ "The type annotation says there " <> sayArgs typeArity <>
      ", but there " <> sayArgs argArity <>
      " named in the definition. It is best practice for each argument\
      \ in the type to correspond to a named argument in the definition,\
      \ so try that first!"
    ]


sayArgs :: Int -> Text
sayArgs n =
  case n of
    0 ->
      "are NO arguments"

    1 ->
      "is 1 argument"

    _ ->
      "are " <> i2t n <> " arguments"



-- MISMATCH HELPERS


ordinalPair :: Int -> Text
ordinalPair number =
  ordinalize (number - 1) <> " and " <> ordinalize number


varName :: Var.Canonical -> Text
varName (Var.Canonical _ opName) =
  functionName opName


maybeFuncName :: Maybe Var.Canonical -> Text
maybeFuncName maybeVar =
  case maybeVar of
    Nothing ->
      "this function"

    Just var ->
      "function " <> varName var



-- MISMTACH REASONS


flipReason :: Reason -> Reason
flipReason reason =
  case reason of
    BadFields fields ->
        BadFields (map (second (fmap flipReason)) fields)

    MessyFields both left right ->
        MessyFields both right left

    IntFloat ->
        IntFloat

    TooLongComparableTuple len ->
        TooLongComparableTuple len

    MissingArgs num ->
        MissingArgs num

    RigidClash a b ->
        RigidClash b a

    NotPartOfSuper super ->
        NotPartOfSuper super

    RigidVarTooGeneric name specific ->
        RigidVarTooGeneric name specific

    RigidSuperTooGeneric super name specific ->
        RigidSuperTooGeneric super name specific


reasonToString :: Reason -> Maybe Doc
reasonToString reason =
  let
    (fields, maybeDeepReason) =
      collectFields reason

    maybeDocs =
      reasonToStringHelp =<< maybeDeepReason

    starter =
      case fields of
        [] ->
          Nothing

        [field] ->
          Just $ "Problem in the `" <> field <> "` field. "

        _ ->
          Just $ "Problem at `" <> Text.intercalate "." fields <> "`. "
  in
    case (starter, maybeDocs) of
      (Nothing, Nothing) ->
        Nothing

      (Just msg, Nothing) ->
        Just $ toHint (msg <> badFieldElaboration)

      (_, Just (firstLine, docs)) ->
        Just $ vcat $
          toHint (maybe firstLine (<> firstLine) starter)
          : map (indent 4) docs



collectFields :: Reason -> ([Text], Maybe Reason)
collectFields reason =
  case reason of
    BadFields [(field, Nothing)] ->
      ([field], Nothing)

    BadFields [(field, Just subReason)] ->
      first (field:) (collectFields subReason)

    _ ->
      ([], Just reason)


reasonToStringHelp :: Reason -> Maybe (Text, [Doc])
reasonToStringHelp reason =
  let
    go msg =
      Just (msg, [])
  in
  case reason of
    BadFields fields ->
      go $
        "I am seeing issues with the "
        <> Help.commaSep (map fst fields) <> " fields. "
        <> badFieldElaboration

    MessyFields both leftOnly rightOnly ->
        messyFieldsHelp both leftOnly rightOnly

    IntFloat ->
        go $
          "Elm does not automatically convert between Ints and Floats. Use\
          \ `toFloat` and `round` to do specific conversions.\
          \ <http://package.elm-lang.org/packages/elm-lang/core/latest/Basics#toFloat>"

    TooLongComparableTuple len ->
        go $
          "Although tuples are comparable, this is currently only supported\
          \ for tuples with 6 or fewer entries, not " <> i2t len <> "."

    MissingArgs num ->
        go $
          "It looks like a function needs " <> Help.moreArgs num <> "."

    RigidClash name1 name2 ->
        go $
          "Your type annotation uses `" <> name1 <> "` and `" <> name2 <>
          "` as DIFFERENT type variables. By using separate names, you are\
          \ claiming the values can be different, but the code suggests that\
          \ they must be the SAME based on how they are used. Maybe these two\
          \ type variables in your type annotation should just be one? Maybe\
          \ your code uses them in a weird way? More help at: "
          <> Help.hintLink "type-annotations"

    NotPartOfSuper Type.Number ->
        go "Only ints and floats are numbers."

    NotPartOfSuper Type.Comparable ->
        go "Only ints, floats, chars, strings, lists, and tuples are comparable."

    NotPartOfSuper Type.Appendable ->
        go "Only strings and lists are appendable."

    NotPartOfSuper Type.CompAppend ->
        go "Only strings and lists are both comparable and appendable."

    RigidVarTooGeneric name specific ->
        go $ rigidTooGenericHelp "ANY type of value" name specific

    RigidSuperTooGeneric Type.Number name specific ->
        go $ rigidTooGenericHelp "BOTH Ints and Floats" name specific

    RigidSuperTooGeneric Type.Comparable name specific ->
        go $ rigidTooGenericHelp "ANY comparable value" name specific

    RigidSuperTooGeneric Type.Appendable name specific ->
        go $ rigidTooGenericHelp "BOTH Strings and Lists" name specific

    RigidSuperTooGeneric Type.CompAppend name specific ->
        go $ rigidTooGenericHelp "Strings and ANY comparable List" name specific


rigidTooGenericHelp :: Text -> Text -> SpecificThing -> Text
rigidTooGenericHelp manyTypesOfValues name specific =
  "The type variable `" <> name <> "` in your type annotation suggests that"
  <> manyTypesOfValues <> " can flow through, but the code suggests that it must be "
  <> specificThingToText specific <> " based on how it is used. Maybe make your\
  \ type annotation more specific? Maybe the code has a problem? More help at: "
  <> Help.hintLink "type-annotations"


specificThingToText :: SpecificThing -> Text
specificThingToText specific =
  case specific of
    SpecificSuper Type.Number ->
      "a number"

    SpecificSuper Type.Comparable ->
      "comparable"

    SpecificSuper Type.Appendable ->
      "appendable"

    SpecificSuper Type.CompAppend ->
      "comparable AND appendable"

    SpecificType var@(Var.Canonical _ name) ->
      if Var.isTuple var then
        "a tuple"

      else if Text.isInfixOf (Text.take 1 name) "AEIOU" then
        "an " <> name

      else
        "a " <> name

    SpecificRecord ->
      "a record"

    SpecificFunction ->
      "a function"


badFieldElaboration :: Text
badFieldElaboration =
  "I always figure out field types in alphabetical order. If a field\
  \ seems fine, I assume it is \"correct\" in subsequent checks.\
  \ So the problem may actually be a weird interaction with previous fields."


messyFieldsHelp :: [Text] -> [Text] -> [Text] -> Maybe (Text, [Doc])
messyFieldsHelp both leftOnly rightOnly =
  case (leftOnly, rightOnly) of
    ([], [missingField]) ->
      oneMissingField both missingField

    ([missingField], []) ->
      oneMissingField both missingField

    ([], missingFields) ->
      manyMissingFields both missingFields

    (missingFields, []) ->
      manyMissingFields both missingFields

    _ ->
      let
        typoPairs =
          case Help.findTypoPairs leftOnly rightOnly of
            [] ->
              Help.findTypoPairs (both ++ leftOnly) (both ++ rightOnly)

            pairs ->
              pairs
      in
        if null typoPairs then
          Just
            ( "The record fields do not match up. One has "
              <> Help.commaSep leftOnly <> ". The other has "
              <> Help.commaSep rightOnly <> "."
            , []
            )

        else
          Just
            ( "The record fields do not match up. Maybe you made one of these typos?"
            , typoDocs "<->" typoPairs
            )


oneMissingField :: [Text] -> Text -> Maybe (Text, [Doc])
oneMissingField knownFields missingField =
  case Help.findPotentialTypos knownFields missingField of
    [] ->
      Just
        ( "Looks like a record is missing the `" <> missingField <> "` field."
        , []
        )

    [typo] ->
      Just
        ( "Looks like a record is missing the `" <> missingField
          <> "` field. Maybe it is a typo?"
        , typoDocs "->" [(missingField, typo)]
        )

    typos ->
      Just
        ( "Looks like a record is missing the `" <> missingField
          <> "` field. It is close to names like "
          <> Help.commaSep typos <> " so maybe it is a typo?"
        , []
        )


manyMissingFields :: [Text] -> [Text] -> Maybe (Text, [Doc])
manyMissingFields knownFields missingFields =
  case Help.findTypoPairs missingFields knownFields of
    [] ->
      Just
        ( "Looks like a record is missing these fields: "
          <> Help.commaSep missingFields
        , []
        )

    typoPairs ->
      Just
        ( "Looks like a record is missing these fields: "
          <> Help.commaSep missingFields
          <> ". Potential typos include:"
        , typoDocs "->" typoPairs
        )


typoDocs :: Text -> [(Text, Text)] -> [Doc]
typoDocs arrow typoPairs =
  let
    maxLen =
      maximum (map (Text.length . fst) typoPairs)
  in
    text "" : map (padTypo arrow maxLen) typoPairs


padTypo :: Text -> Int -> (Text, Text) -> Doc
padTypo arrow maxLen (missingField, knownField) =
  text (Text.replicate (maxLen - Text.length missingField) " ")
  <> dullyellow (text missingField)
  <+> text arrow
  <+> dullyellow (text knownField)



-- INFINITE TYPES


infiniteTypeToReport :: RenderType.Localizer -> Either Hint Text -> Type.Canonical -> Report.Report
infiniteTypeToReport localizer context overallType =
  let
    (maybeRegion, description) =
      case context of
        Right name ->
          ( Nothing, functionName name )
        Left hint ->
          infiniteHint hint
  in
    Report.report
      "INFINITE TYPE"
      maybeRegion
      ( "I am inferring a weird self-referential type for " <> description <> ":"
      )
      ( stack
          [ reflowParagraph $
              "Here is my best effort at writing down the type. You will see ∞ for\
              \ parts of the type that repeat something already printed out infinitely."
          , indent 4 (RenderType.toDoc localizer overallType)
          , reflowParagraph $
              "Usually staring at the type is not so helpful in these cases, so definitely\
              \ read the debugging hints for ideas on how to figure this out: "
              <> Help.hintLink "infinite-type"
          ]
      )


infiniteHint :: Hint -> (Maybe Region.Region, Text)
infiniteHint hint =
  case hint of
    CaseBranch n region ->
      ( Just region, "the " <> ordinalize n <> " `case` branch" )

    Case ->
      ( Nothing, "this `case` expression" )

    IfCondition ->
      ( Nothing, "the `if` condition" )

    IfBranches ->
      ( Nothing, "the `if` branches" )

    MultiIfBranch n region ->
      ( Just region, "the " <> ordinalize n <> " `if` branch" )

    If ->
      ( Nothing, "this `if` expression" )

    List ->
      ( Nothing, "this list" )

    ListElement n region ->
      ( Just region, "the " <> ordinalize n <> " list entry" )

    BinopLeft _ region ->
      ( Just region, "the left argument" )

    BinopRight _ region ->
      ( Just region, "the right argument" )

    Binop _ ->
      ( Nothing, "this expression" )

    Function maybeName ->
      ( Nothing, maybeFuncName maybeName )

    UnexpectedArg maybeName 1 1 region ->
      ( Just region, "the argument to " <> maybeFuncName maybeName )

    UnexpectedArg maybeName index _total region ->
      ( Just region, "the " <> ordinalize index <> " argument to " <> maybeFuncName maybeName )

    FunctionArity maybeName _ _ region ->
      ( Just region, maybeFuncName maybeName )

    ReturnType name _ _ region ->
      ( Just region, functionName name )

    Instance name ->
      ( Nothing, functionName name )

    Literal name ->
      ( Nothing, name )

    Pattern _ ->
      ( Nothing, "this pattern" )

    Shader ->
      ( Nothing, "this shader" )

    Lambda ->
      ( Nothing, "this function" )

    Access _ _ ->
      ( Nothing, "this field access" )

    Record ->
      ( Nothing, "this record" )

    -- effect manager problems
    Manager name ->
      ( Nothing, functionName name )

    State name ->
      ( Nothing, functionName name )

    SelfMsg ->
      ( Nothing, "this code" )
