########################################################################
# File:    loader_helper.rb                                            #
#          Based on work by Hipposoft 2008                             #
#                                                                      #
# Purpose: Support functions for views related to Task Import objects. #
#          See controllers/loader_controller.rb for more.              #
#                                                                      #
# History: 04-Jan-2008 (ADH): Created.                                 #
#          Feb 2009 (SJS): Hacked into plugin for redmine              #
########################################################################

module LoaderHelper
  

  # Generate a category selector to which imported tasks will
  # be assigned. HTML is output which is suitable for inclusion in a table
  # cell or other similar container. Pass the form object being used for the
  # task import view.
  
  def loaderhelp_category_selector( fieldId, project, allNewCategories, requestedCategory )

    # First populate the selection box with all the existing categories from this project
    existingCategoryList = IssueCategory.find :all, :conditions => { :project_id => project }
        
    output = "<select id=\"" + fieldId + "\" name=\"" + fieldId + "\"><optgroup label=\"Existing Categories\"> "

    existingCategoryList.each do | category_info |
      if ( category_info.to_s == requestedCategory )
        output << "<option value=\"" + category_info.to_s + "\" selected>" + category_info.to_s + "</option>"
      else
        output << "<option value=\"" + category_info.to_s + "\">" + category_info.to_s + "</option>"
      end
    end

    output << "</optgroup>"

    # Now add any new categories that we found in the project file
    output << "<optgroup label=\"New Categories\"> "

    allNewCategories.each do | category_name |
      if ( not existingCategoryList.include?(category_name) )
        if ( category_name == requestedCategory )
          output << "<option value=\"" + category_name + "\" selected>" + category_name + "</option>"
        else
          output << "<option value=\"" + category_name + "\">" + category_name + "</option>"
        end
      end
    end

    output << "</optgroup>"

    output << "</select>"

    return output
  end

  # Generate a user selector to which imported tasks will
  # be assigned. HTML is output which is suitable for inclusion in a table
  # cell or other similar container. Pass the form object being used for the
  # task import view.

  def loaderhelp_user_selector( fieldId, project, task )

    # First populate the selection box with all the existing categories from this project
    memberList = Member.find( :all, :conditions => { :project_id => project } )

    userList = []
    
    memberList.each do | current_member |
      userList.push( User.find( :first, :conditions => { :id => current_member.user_id } ) )
    end
  
    userList.compact!

    output = "<select id=\"" + fieldId + "\" name=\"" + fieldId + "\">"

    # Empty entry
    output << "<option value=\"\"></option>"

    # Add all the users
    userList = userList.sort { |a,b| a.firstname + a.lastname <=> b.firstname + b.lastname }
    userList.each do | user_entry |
      output << "<option value=\"" + user_entry.id.to_s + "\""
      unless (task.users.nil? || task.users.empty?)
        if task.users[0] == user_entry.id
          output << " selected "
        end
      end
      output << ">" + user_entry.firstname + " " + user_entry.lastname + " </option>"
    end

    output << "</select>"

    return output

  end
  
end